# frozen_string_literal: true

require_relative "operator_and_partner_policy_test"
require "active_model"
require "minitest/mock"
require "uri"
require "action_view"
require "nokogiri"
require_relative "../../../../app/services/decidim/bih/governance/approval_recorder"

module Decidim
  module Bih
    # The real model contract runs without Rails/database boot. Persistence and
    # authenticated form submission remain in the host governance integration test.
    class LocalReleaseApprovalTest < Minitest::Test
      def setup
        @policy = {
          "version" => 2, "execution" => "local",
          "verification" => {
            "lanes" => {
              "docs" => { "required_scopes" => %w(static secret_scan) },
              "fast" => { "required_scopes" => %w(static secret_scan targeted eager_load) },
              "deep" => { "required_scopes" => %w(structural secret_scan app_suite engine_suite eager_load static_analysis) }
            },
            "conditional_scopes" => { "comprehensive" => %w(engine_clean_host engine_rails_test) }
          }
        }
      end

      def test_each_lane_accepts_its_actual_local_pass_without_fabricating_full_or_external_status
        %w(docs fast deep).each do |lane|
          with_policy do
            approval = build(lane:)
            assert approval.valid?, approval.errors.attribute_names.inspect
            assert_nil approval.local_full_gate_status
            assert_nil approval.external_ci_status
            assert approval.local_verification_matches?(result: receipt(approval), result_digest: approval.verification_result_digest)
          end
        end
      end

      def test_missing_failed_skipped_or_not_applicable_local_gate_cannot_approve
        [nil, "", "failed", "skipped", "not_applicable"].each do |value|
          with_policy do
            approval = build
            approval.metadata["local_gate_status"] = value
            refute approval.valid?
            assert_includes approval.errors.attribute_names, :local_gate_status
          end
        end
      end

      def test_required_scope_cannot_be_removed_or_arbitrarily_added
        [[], %w(static secret_scan), %w(static secret_scan targeted eager_load arbitrary_skip)].each do |scopes|
          with_policy do
            approval = build
            approval.metadata["required_scopes"] = scopes
            refute approval.valid?
            assert_includes approval.errors.attribute_names, :required_scopes
          end
        end
      end

      def test_policy_listed_comprehensive_scopes_must_match_receipt_and_pass
        with_policy do
          approval = build(lane: "deep")
          approval.metadata["required_scopes"] += %w(engine_clean_host engine_rails_test)
          assert approval.valid?
          result = receipt(approval)
          result["passed_scopes"] -= ["engine_rails_test"]
          refute approval.local_verification_matches?(result:, result_digest: approval.verification_result_digest)
        end
      end

      def test_receipt_requires_exact_pair_policy_lane_scopes_digest_and_real_success
        with_policy do
          approval = build
          changes = {
            "schema_version" => 0, "execution" => "github", "status" => "failed",
            "clean_candidate" => false, "app_sha" => "d" * 40, "engine_sha" => "d" * 40,
            "lane" => "deep", "policy_sha256" => "d" * 64,
            "required_scopes" => [], "passed_scopes" => []
          }
          changes.each do |key, value|
            refute approval.local_verification_matches?(result: receipt(approval).merge(key => value), result_digest: approval.verification_result_digest), key
          end
          refute approval.local_verification_matches?(result: receipt(approval), result_digest: "sha256:#{"d" * 64}")
          approval.status = "blocked"
          refute approval.local_verification_matches?(result: receipt(approval), result_digest: approval.verification_result_digest)
        end
      end

      def test_owner_identity_backup_and_existing_release_boundaries_remain_required
        with_policy do
          {
            approval_role: "admin", app_sha: "a" * 7, scope_key: "other",
            restart_window_ends_at: 48.hours.from_now,
            backup_health_status: "not_applicable", restore_smoke_status: "not_applicable",
            backup_manifest_digest: "bad", migration_state: "unknown",
            user: Struct.new(:organization) { def admin? = false }.new(:organization)
          }.each do |field, value|
            approval = build
            approval.public_send("#{field}=", value)
            refute approval.valid?, field.to_s
          end
        end
      end

      def test_new_approvals_cannot_fall_back_to_legacy_or_forge_retired_columns
        with_policy do
          approval = build
          approval.metadata = {}
          refute approval.valid?
          [:local_fast_gate_status, :local_full_gate_status, :external_ci_status, :branch_protection_status].each do |field|
            approval = build
            approval.public_send("#{field}=", "passed")
            refute approval.valid?, field.to_s
          end
        end
      end

      def test_policy_change_and_missing_policy_fail_closed
        with_policy do
          approval = build
          approval.metadata["verification_policy_sha256"] = "f" * 64
          refute approval.valid?
        end
        GovernanceApproval.stub(:local_verification_policy, -> { raise Errno::ENOENT }) do
          refute build.valid?
        end
      end

      def test_historical_external_rows_keep_their_original_contract_without_local_matching
        approval = build
        approval.metadata = {}
        approval.define_singleton_method(:new_record?) { false }
        approval.local_fast_gate_status = "passed"
        approval.local_full_gate_status = "not_applicable"
        approval.external_ci_status = "not_applicable"
        approval.branch_protection_status = "deferred_by_owner"
        before = [approval.local_full_gate_status, approval.external_ci_status, approval.metadata.dup]
        assert approval.valid?
        refute approval.local_verification_matches?(result: {}, result_digest: "sha256:#{"e" * 64}")
        assert_equal before, [approval.local_full_gate_status, approval.external_ci_status, approval.metadata]
      end

      def test_recorder_derives_policy_and_mandatory_scopes_and_discards_retired_input
        with_policy do
          attrs = {
            "governance_kind" => "release_restart", "status" => "approved", "verification_lane" => "fast",
            "local_gate_status" => "passed", "verification_result_digest" => "sha256:#{"e" * 64}",
            "verification_policy_sha256" => "forged", "required_scopes" => ["engine_clean_host"],
            "external_ci_status" => "passed", "local_full_gate_status" => "passed"
          }
          recorder = Governance::ApprovalRecorder.new(organization: :organization, actor: :actor, role: "admin", attributes: attrs, runbook: "runbook")
          captured = nil
          GovernanceApproval.stub(:new, ->(**values) { captured = values }) { recorder.send(:build_approval) }
          metadata = captured.fetch(:metadata)
          assert_equal "c" * 64, metadata.fetch("verification_policy_sha256")
          assert_equal %w(static secret_scan targeted eager_load engine_clean_host).sort, metadata.fetch("required_scopes")
          refute captured.has_key?(:external_ci_status)
          refute captured.has_key?(:local_full_gate_status)
          assert_equal metadata, GovernanceApproval.sanitize_metadata(metadata)
        end
      end

      def test_rendered_release_form_has_explicit_local_evidence_and_no_retired_inputs
        with_policy do
          form = render_form
          %w(verification_lane local_gate_status verification_result_digest).each do |field|
            assert_equal 1, form.css("[name='governance_approval[#{field}]'][required]").length
          end
          %w(local_fast_gate_status local_full_gate_status external_ci_status branch_protection_status).each do |field|
            assert_empty form.css("[name='governance_approval[#{field}]']")
          end
          assert_empty form.css("[name='governance_approval[local_gate_status]'] option[value='passed'][selected]")
          assert_empty form.css("[name='governance_approval[local_gate_status]'] option[value='not_applicable']")
          options = form.css("[name='governance_approval[required_scopes][]'] option").map { |option| option["value"] }
          assert_equal %w(engine_clean_host engine_rails_test), options
        end
      end

      def test_rendered_release_form_fails_closed_when_policy_missing_and_nonadmins_cannot_submit
        GovernanceApproval.stub(:local_verification_policy_available?, false) do
          assert_empty render_form.css("form")
        end
        with_policy { assert_empty render_form(admin: false).css("form") }
      end

      private

      def render_form(admin: true)
        root = File.expand_path("../../../..", __dir__)
        I18n.load_path |= [File.join(root, "config/locales/sr.yml"), File.join(root, "config/locales/governance_local_verification.yml")]
        I18n.available_locales |= [:sr]
        view = ActionView::Base.with_empty_template_cache.with_view_paths(File.join(root, "app/views"))
        view.assign(governance_storage_available: true, governance_rows: [{ id: "release_restart" }])
        view.define_singleton_method(:add_decidim_page_title) { |_| nil }
        view.define_singleton_method(:current_user) { Struct.new(:admin?).new(admin) }
        view.define_singleton_method(:form_authenticity_token) { "test-csrf" }
        view.define_singleton_method(:governance_approvals_path) { |kind| "/admin/bih/governance/#{kind}/approvals" }
        # Navigation has independent route/helper requirements; exercise the actual
        # governance template and Rails form helpers without mounting a host app.
        view.define_singleton_method(:render) do |*args, **kwargs|
          next "" if args.first == "decidim/bih/admin/shared/navigation"

          super(*args, **kwargs)
        end
        html = I18n.with_locale(:sr) { view.render(template: "decidim/bih/admin/governance/index") }
        Nokogiri::HTML.fragment(html)
      end

      def with_policy(&block)
        GovernanceApproval.stub(:local_verification_policy, @policy) do
          GovernanceApproval.stub(:local_verification_policy_sha256, "c" * 64, &block)
        end
      end

      def build(lane: "fast")
        approval = GovernanceApproval.allocate
        fields = {
          governance_kind: "release_restart", status: "approved", approval_role: "technical_release_owner",
          app_sha: "a" * 40, engine_sha: "b" * 40,
          scope_key: GovernanceApproval.release_scope_key("a" * 40, "b" * 40),
          restart_window_starts_at: 1.hour.ago, restart_window_ends_at: 1.hour.from_now,
          backup_health_status: "passed", restore_smoke_status: "passed",
          backup_manifest_digest: "sha256:#{"d" * 64}", migration_state: "no_pending",
          organization: :organization,
          user: Struct.new(:organization) { def admin? = true }.new(:organization),
          local_fast_gate_status: nil, local_full_gate_status: nil, external_ci_status: nil, branch_protection_status: nil,
          metadata: {
            "verification_lane" => lane, "local_gate_status" => "passed",
            "verification_result_digest" => "sha256:#{"e" * 64}", "verification_policy_sha256" => "c" * 64,
            "required_scopes" => @policy.dig("verification", "lanes", lane, "required_scopes").dup
          }
        }
        fields.each do |key, value|
          approval.singleton_class.attr_accessor key
          approval.public_send("#{key}=", value)
        end
        approval.define_singleton_method(:new_record?) { true }
        approval.define_singleton_method(:errors) { @contract_errors ||= ActiveModel::Errors.new(self) }
        approval.define_singleton_method(:valid?) do
          errors.clear
          send(:release_restart_contract)
          errors.empty?
        end
        approval
      end

      def receipt(approval)
        {
          "schema_version" => 1, "execution" => "local", "status" => "passed", "clean_candidate" => true,
          "app_sha" => approval.app_sha, "engine_sha" => approval.engine_sha, "lane" => approval.verification_lane,
          "policy_sha256" => approval.verification_policy_sha256,
          "required_scopes" => approval.required_scopes.dup, "passed_scopes" => approval.required_scopes.dup
        }
      end
    end
  end
end
