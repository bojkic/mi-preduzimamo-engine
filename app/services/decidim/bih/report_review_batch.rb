# frozen_string_literal: true

require "securerandom"

module Decidim
  module Bih
    # Each encrypted approval is bound to one human, tenant, case and version.
    # There is deliberately no transaction around the entire batch: one stale
    # or invalid item must not roll back another independently approved case.
    class ReportReviewBatch
      MAX_ITEMS = 25
      PURPOSE = "report-review-batch"
      SALT = "bih-report-review-batch-v1"
      EXPIRY = 10.minutes
      ACTIONS = (ReportDecision::ACTIONS - %w(save_draft claim assign note message)).freeze
      Result = Struct.new(:reference, :state, :action, :decision_values, :snapshot, :token, :error, keyword_init: true)

      def initialize(organization:, actor:)
        @organization = organization
        @actor = actor
      end

      # Preparation performs no approval or sends. For mail it computes the
      # same exact content as the single-case confirmation screen.
      def prepare(entries)
        authorize!
        bounded!(entries)
        seen = {}
        entries.map do |entry|
          reference = nil
          begin
            item = entry.to_h.stringify_keys
            reference = item["reference"].to_s
            report = Report.find_by!(organization: @organization, reference:)
            invalid!(:invalid_action) if seen[report.id]
            seen[report.id] = true
            action, values, version = validate_item(report, item)

            snapshot = ReportDecision.new(report, @actor).preview(action:, values:, version:) if ReportDecision::SEND_ACTIONS.include?(action)
            token = envelope.seal({ actor_id: @actor.id, organization_id: @organization.id, report_id: report.id, reference:,
                                    action:, values:, version:, mail_digest: snapshot&.fetch(:digest), approval_key: SecureRandom.uuid,
                                    expires_at: EXPIRY.from_now.to_i }, purpose: PURPOSE, salt: SALT)
            Result.new(reference:, state: "prepared", action:, decision_values: values, snapshot:, token:)
          rescue StandardError => e
            failure(reference, e)
          end
        end
      end

      # Only explicitly checked items execute; browser-provided values/actions
      # are ignored here. Permissions and case version are checked again inside
      # the common decision service at the actual moment of approval.
      def apply(entries)
        authorize!
        bounded!(entries)
        entries.map do |entry|
          reference = nil
          begin
            item = entry.to_h.stringify_keys
            payload = envelope.open(item["token"], purpose: PURPOSE, salt: SALT)
            invalid!(:preview_required) unless payload["actor_id"] == @actor.id && payload["organization_id"] == @organization.id &&
                                               payload["expires_at"].to_i > Time.current.to_i && payload["approval_key"].present?
            reference = payload.fetch("reference")
            next Result.new(reference:, state: "skipped", action: payload["action"]) unless item["approve"] == "1"

            report = Report.find_by!(organization: @organization, id: payload.fetch("report_id"), reference:)
            result = ReportDecision.new(report, @actor, approval_key: payload.fetch("approval_key")).call(action: payload.fetch("action"), values: payload.fetch("values"),
                                                                                                          version: payload.fetch("version"), confirmed: true,
                                                                                                          approved_mail_digest: payload["mail_digest"])
            Result.new(reference:, state: result.is_a?(ReportDispatch) ? "queued" : "applied", action: payload["action"])
          rescue StandardError => e
            failure(reference, e)
          end
        end
      end

      private

      def validate_item(report, item)
        action = item["action"].to_s
        invalid!(:invalid_action) unless ACTIONS.include?(action)
        values = item.fetch("values", {}).to_h.stringify_keys.slice(*ReportDecision::FIELDS.map(&:to_s))
        invalid!(:too_large) if values.to_json.bytesize > 24_000
        version = item["version"].to_s
        invalid!(:stale) unless version == ReportReviewVersion.digest(report)
        invalid!(:not_ready) unless ReportDecision.allowed_actions(report).include?(action)
        permission = ReportDecision::PERMISSIONS.fetch(action, :reports_update_status)
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(@actor, permission, organization: @organization)

        [action, values, version]
      end

      def envelope = Infobip::EncryptedJobEnvelope

      def authorize!
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(@actor, :reports_read, organization: @organization) &&
                                              OperatorAuthorization.allowed?(@actor, :reports_update_status, organization: @organization)
      end

      def bounded!(entries)
        invalid!(:too_large) unless entries.is_a?(Array) && entries.size.between?(1, MAX_ITEMS)
      end

      def invalid!(key)
        raise ReportDecision::Invalid, I18n.t("decidim.bih.review_workspace.errors.#{key}")
      end

      def failure(reference, error)
        expected = [ReportDecision::Invalid, ReportDispatching::Invalid, ReportPlanning::Invalid, ReportCaseWorkflow::Invalid]
        message = if expected.any? { |type| error.is_a?(type) }
                    error.message
                  else
                    Rails.logger.warn("[ReportReviewBatch] item failed error=#{error.class}")
                    I18n.t("decidim.bih.review_workspace.errors.preview_required")
                  end
        Result.new(reference:, state: "failed", error: message)
      end
    end
  end
end
