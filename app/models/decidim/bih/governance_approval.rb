# frozen_string_literal: true

require "digest"
require "yaml"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/string/filters"

module Decidim
  module Bih
    # Append-only, PII-minimized approval record for operational governance.
    class GovernanceApproval < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_governance_approvals"

      GOVERNANCE_KINDS = %w(
        viber_launch
        external_chat_launch
        release_restart
        backup_restore
        cron_maintenance
        privacy_retention
      ).freeze

      STATUSES = %w(approved needs_follow_up blocked).freeze
      RELEASE_APPROVAL_ROLE = "technical_release_owner"
      RELEASE_GATE_STATUSES = %w(passed not_applicable).freeze
      BRANCH_PROTECTION_STATUSES = %w(verified blocked_by_repository_plan deferred_by_owner).freeze
      MIGRATION_STATES = %w(no_pending pending_reviewed).freeze

      # Approval validity follows the risk/evidence cadence of each workflow.
      # These are deliberately not one generic dashboard threshold.
      VALIDITY_WINDOWS = {
        "viber_launch" => 90.days,
        "external_chat_launch" => 90.days,
        "release_restart" => 7.days,
        "backup_restore" => 31.days,
        "cron_maintenance" => 31.days,
        "privacy_retention" => 7.days
      }.freeze

      ALLOWED_METADATA_KEYS = %w(
        dry_run_status
        dry_run_total
        release_window
        recorded_from
        runbook
        smoke_status
        verification_lane
        local_gate_status
        verification_result_digest
        verification_policy_sha256
        required_scopes
      ).freeze

      FORBIDDEN_METADATA_KEYS = %w(
        address api_key authorization backup_path bearer body command_output contact
        credential database_url description dump_path email internal_note ip_address
        log_line message note params password payload phone private_key provider_payload
        raw raw_log recipient_list report_description request_ip response_body secret
        session_digest shell_history status_token token user_agent viber_id viber_sender
      ).freeze

      SECRET_TEXT_PATTERN = /
        api[_-]?key|authorization|bearer\s+[a-z0-9._-]+|database_url|github_pat|
        password|private[_ -]?key|secret|token|-----BEGIN
      /ix

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id"

      belongs_to :operator_audit_event,
                 class_name: "Decidim::Bih::OperatorAuditEvent",
                 optional: true

      belongs_to :secondary_approver,
                 class_name: "Decidim::User",
                 optional: true

      has_one :secondary_attestation,
              class_name: "Decidim::Bih::GovernanceApprovalAttestation",
              inverse_of: :governance_approval,
              dependent: :restrict_with_exception

      before_validation :set_defaults
      before_validation :normalize_fields
      before_validation :sanitize_metadata

      validates :governance_kind, inclusion: { in: GOVERNANCE_KINDS }
      validates :approval_role, presence: true, length: { maximum: 64 }
      validates :status, inclusion: { in: STATUSES }
      validates :scope_key, length: { maximum: 160 }, allow_blank: true
      validates :app_sha, :engine_sha,
                format: { with: /\A[0-9a-f]{7,64}\z/ },
                allow_blank: true
      validates :evidence_summary, presence: true, length: { maximum: 1_000 }
      validates :evidence_digest, presence: true, length: { maximum: 128 }
      validates :approved_at, presence: true
      validate :text_fields_do_not_contain_secret_markers
      validate :release_restart_contract

      scope :recent, -> { order(approved_at: :desc, id: :desc) }
      scope :for_kind, ->(kind) { where(governance_kind: kind) }

      LOCAL_VERIFICATION_FIELDS = %w(
        verification_lane local_gate_status verification_result_digest
        verification_policy_sha256 required_scopes
      ).freeze

      LOCAL_VERIFICATION_FIELDS.each do |field|
        define_method(field) { (metadata || {})[field] }
      end

      def self.local_verification_policy
        YAML.safe_load_file(Rails.root.join("docs/operations/release-approval-policy.yml"))
      end

      def self.local_verification_policy_available?
        policy = local_verification_policy
        policy["version"] == 2 && policy["execution"] == "local" &&
          policy.fetch("verification").fetch("lanes").keys.sort == %w(deep docs fast) &&
          additional_verification_scopes.is_a?(Array)
      rescue KeyError, TypeError, NoMethodError, Errno::ENOENT, Psych::Exception
        false
      end

      def self.local_verification_policy_sha256
        Digest::SHA256.file(Rails.root.join("docs/operations/release-approval-policy.yml")).hexdigest
      end

      def self.verification_scopes(lane)
        local_verification_policy.fetch("verification").fetch("lanes").fetch(lane).fetch("required_scopes")
      end

      def self.additional_verification_scopes
        local_verification_policy.fetch("verification").fetch("conditional_scopes").values.flatten.uniq
      end

      def local_verification?
        verification_lane.present?
      end

      # Call only with the coordinator's verified local receipt. File provenance,
      # freshness, toolchain and test signature are checked by that verifier.
      # This binds authenticated approval to that exact receipt, not a green ancestor.
      def local_verification_matches?(result:, result_digest:)
        return false unless governance_kind == "release_restart" && status == "approved" && local_verification? && valid?

        expected = {
          "schema_version" => 1, "execution" => "local", "status" => "passed", "clean_candidate" => true,
          "app_sha" => app_sha, "engine_sha" => engine_sha, "lane" => verification_lane,
          "policy_sha256" => verification_policy_sha256
        }
        result.is_a?(Hash) && expected.all? { |key, value| result[key] == value } &&
          result_digest == verification_result_digest && local_verification_scopes_match?(result)
      end

      def readonly?
        persisted? && operator_audit_event_id_in_database.present?
      end

      def valid_until
        approved_at + VALIDITY_WINDOWS.fetch(governance_kind)
      end

      def current_approval?(at: Time.current)
        status == "approved" && approved_at <= at && valid_until >= at
      end

      # Retained for compatibility with historical release records. Independent
      # attestation is no longer required for a release approval to be current.
      def independently_attested?
        secondary_attestation.present?
      end

      def stale?(at: Time.current)
        valid_until < at
      end

      def self.current_for(organization, kind, at: Time.current)
        approval = latest_by_kind(organization)[kind.to_s]
        approval if approval&.current_approval?(at:)
      end

      def self.release_scope_key(app_sha, engine_sha)
        "release:#{app_sha}:#{engine_sha}"
      end

      def self.external_chat_scope_key(channels)
        normalized = Array(channels).map { |channel| channel.to_s.strip.downcase }
                                    .select { |channel| %w(whatsapp messenger instagram).include?(channel) }
                                    .uniq
                                    .sort
        "external_chat:#{normalized.join(",")}"
      end

      def self.current_release_for(organization, app_sha:, engine_sha:, backup_manifest_digest:, at: Time.current)
        return unless storage_available?

        for_kind("release_restart")
          .where(
            organization:,
            status: "approved",
            app_sha:,
            engine_sha:,
            scope_key: release_scope_key(app_sha, engine_sha),
            backup_manifest_digest:
          )
          .where("restart_window_starts_at <= ? AND restart_window_ends_at >= ?", at, at)
          .recent
          .detect { |approval| approval.current_approval?(at:) && approval.valid? }
      end

      def self.latest_by_kind(organization)
        return {} unless storage_available?

        where(organization:)
          .recent
          .each_with_object({}) { |approval, by_kind| by_kind[approval.governance_kind] ||= approval }
      end

      # Governance was introduced with a host migration. During a rolling
      # release, or when a deploy restarts before pending engine migrations are
      # applied, the route must remain a usable runbook handoff instead of
      # raising PG::UndefinedTable. Writes stay disabled until storage exists.
      def self.storage_available?
        connection.data_source_exists?(table_name)
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def self.sanitize_metadata(metadata)
        metadata.to_h.each_with_object({}) do |(key, value), sanitized|
          key = key.to_s
          next if key.blank? || FORBIDDEN_METADATA_KEYS.include?(key)
          next unless ALLOWED_METADATA_KEYS.include?(key)

          sanitized[key] = sanitize_metadata_value(value)
        end
      end

      def self.sanitize_metadata_value(value)
        case value
        when Hash
          sanitize_metadata(value)
        when Array
          value.first(20).map { |item| sanitize_metadata_value(item) }
        when Numeric, TrueClass, FalseClass
          value
        else
          value.to_s.squish[0, 255]
        end
      end

      def self.safe_evidence_digest(summary)
        "sha256:#{Digest::SHA256.hexdigest(summary.to_s.squish)}"
      end

      private

      def set_defaults
        self.approved_at ||= Time.current
        self.approval_role ||= "admin"
        self.metadata ||= {}
      end

      def normalize_fields
        self.governance_kind = governance_kind.to_s
        self.approval_role = approval_role.to_s.squish
        self.status = status.to_s
        self.scope_key = scope_key.to_s.squish.presence
        self.app_sha = app_sha.to_s.strip.presence
        self.engine_sha = engine_sha.to_s.strip.presence
        self.evidence_summary = evidence_summary.to_s.squish
        self.evidence_digest = evidence_digest.to_s.squish.presence || self.class.safe_evidence_digest(evidence_summary)
        self.secondary_approval_role = secondary_approval_role.to_s.squish.presence
        self.local_fast_gate_status = local_fast_gate_status.to_s.squish.presence
        self.local_full_gate_status = local_full_gate_status.to_s.squish.presence
        self.external_ci_status = external_ci_status.to_s.squish.presence
        self.branch_protection_status = branch_protection_status.to_s.squish.presence
        self.backup_health_status = backup_health_status.to_s.squish.presence
        self.restore_smoke_status = restore_smoke_status.to_s.squish.presence
        self.backup_manifest_digest = backup_manifest_digest.to_s.squish.presence
        self.migration_state = migration_state.to_s.squish.presence
      end

      def sanitize_metadata
        self.metadata = self.class.sanitize_metadata(metadata || {})
      end

      def text_fields_do_not_contain_secret_markers
        {
          scope_key:,
          app_sha:,
          engine_sha:,
          evidence_summary:,
          evidence_digest:
        }.each do |attribute, value|
          next if value.blank?
          next unless value.to_s.match?(SECRET_TEXT_PATTERN)

          errors.add(attribute, :invalid)
        end
      end

      def release_restart_contract
        return unless governance_kind == "release_restart" && status == "approved"

        errors.add(:approval_role, :inclusion) unless approval_role == RELEASE_APPROVAL_ROLE
        validate_release_identity
        validate_release_window
        if new_record? || local_verification?
          validate_local_verification
        else
          validate_release_statuses # Historical rows keep their original contract.
        end
        errors.add(:backup_manifest_digest, :invalid) unless backup_manifest_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
        errors.add(:migration_state, :inclusion) unless MIGRATION_STATES.include?(migration_state)
      end

      def validate_release_identity
        errors.add(:app_sha, :invalid) unless app_sha.to_s.match?(/\A[0-9a-f]{40}\z/)
        errors.add(:engine_sha, :invalid) unless engine_sha.to_s.match?(/\A[0-9a-f]{40}\z/)
        expected_scope = self.class.release_scope_key(app_sha, engine_sha)
        errors.add(:scope_key, :invalid) unless scope_key == expected_scope
      end

      def validate_release_window
        if restart_window_starts_at.blank? || restart_window_ends_at.blank?
          errors.add(:restart_window_starts_at, :blank)
        elsif restart_window_ends_at <= restart_window_starts_at ||
              restart_window_ends_at - restart_window_starts_at > 24.hours
          errors.add(:restart_window_ends_at, :invalid)
        end
      end

      def local_verification_scopes_match?(result)
        result["required_scopes"].is_a?(Array) && result["passed_scopes"].is_a?(Array) &&
          result["required_scopes"].sort == required_scopes.sort &&
          (required_scopes - result["passed_scopes"]).empty?
      rescue ArgumentError
        false
      end

      def validate_local_verification
        policy = self.class.local_verification_policy
        lanes = policy.fetch("verification").fetch("lanes")
        validate_local_verification_identity(lanes)
        validate_local_verification_scopes(lanes.dig(verification_lane, "required_scopes"))
        validate_local_verification_controls
        errors.add(:user, :invalid) unless user&.admin? && user.organization == organization
        errors.add(:verification_lane, :invalid) unless policy["execution"] == "local" && policy["version"] == 2
      rescue KeyError, TypeError, NoMethodError, Errno::ENOENT, Psych::Exception
        errors.add(:verification_lane, :invalid)
      end

      def validate_local_verification_identity(lanes)
        errors.add(:verification_lane, :inclusion) unless lanes.has_key?(verification_lane)
        errors.add(:local_gate_status, :inclusion) unless local_gate_status == "passed"
        errors.add(:verification_result_digest, :invalid) unless verification_result_digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
        errors.add(:verification_policy_sha256, :invalid) unless verification_policy_sha256 == self.class.local_verification_policy_sha256
      end

      def validate_local_verification_scopes(base_scopes)
        allowed_scopes = Array(base_scopes) + self.class.additional_verification_scopes
        unless required_scopes.is_a?(Array) && base_scopes.present? &&
               (base_scopes - required_scopes).empty? && (required_scopes - allowed_scopes).empty? &&
               required_scopes.uniq == required_scopes
          errors.add(:required_scopes, :invalid)
        end
      end

      def validate_local_verification_controls
        [:backup_health_status, :restore_smoke_status].each do |attribute|
          errors.add(attribute, :inclusion) unless public_send(attribute) == "passed"
        end
        # Retired columns remain readable on historical rows, never invented on new ones.
        [:local_fast_gate_status, :local_full_gate_status, :external_ci_status, :branch_protection_status].each do |attribute|
          errors.add(attribute, :invalid) if public_send(attribute).present?
        end
      end

      def validate_release_statuses
        [
          :local_fast_gate_status,
          :local_full_gate_status,
          :external_ci_status,
          :backup_health_status,
          :restore_smoke_status
        ].each do |attribute|
          errors.add(attribute, :inclusion) unless RELEASE_GATE_STATUSES.include?(public_send(attribute))
        end
        errors.add(:branch_protection_status, :inclusion) unless BRANCH_PROTECTION_STATUSES.include?(branch_protection_status)
      end
    end
  end
end
