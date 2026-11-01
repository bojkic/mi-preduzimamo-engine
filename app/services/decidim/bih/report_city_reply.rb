# frozen_string_literal: true

module Decidim
  module Bih
    class ReportCityReply
      def self.record!(report:, inbound_email:, link:)
        return if inbound_email.history_only
        InboundEmailEffect.once!(inbound_email:, report:, effect: "service_response") do
          report.record_event!("city_email_received", source: "background", metadata: { inbound_email_id: inbound_email.id, received_at: inbound_email.internal_date.iso8601, from_digest: inbound_email.from_digest, assurance: link.assurance, matching_method: link.matching_method, file_numbers: inbound_email.file_numbers })
          # Phase 1 is additive during the race freeze: the event requests staff
          # review without changing any legacy status or race-read review field.
          StaffNotice.call(report:, inbound_email:, reason: "service_response")
          ActiveRecord.after_all_transactions_commit { ReportReviewAssistant.enqueue(report) }
        end
      end
      class StaffNotice
        OBLIGATION_KINDS = { "mail_review" => "mail_review", "delivery_exception" => "delivery_exception",
          "service_response" => "review", "citizen_after_closure" => "dispute_review" }.freeze

        def self.call(report:, inbound_email:, reason:)
          return if inbound_email.history_only
          kind = OBLIGATION_KINDS[reason]
          if kind && defined?(ReportObligation) && ReportObligation.available?
            ReportObligations.open!(report, kind:, actor: "staff", source: inbound_email,
              effect_key: effect_key(report, inbound_email, kind), metadata: { inbound_email_id: inbound_email.id, reason: })
          end
          ReportCaseWorkflow.staff(report.organization).each do |user|
            # The resource is the staff user, as for every other staff bell: a
            # report has no can_participate?, which broke /notifications (2026-10-06).
            Decidim::Notification.create!(user:, resource: user, event_name: "decidim.events.bih.report_case_message", event_class: "Decidim::Bih::ReportCaseMessageEvent", extra: { report_id: report.id, reference: report.reference, inbound_email_id: inbound_email.id, reason: })
          end
        end
        # Complete only this producer's mail-triage tasks. Interpretation may
        # open a separate uncertain-response review that must remain actionable.
        def self.fulfil_review!(report:, inbound_email:, by:, kinds: %w(review mail_review), producer_only: true)
          return unless defined?(ReportObligation) && ReportObligation.available?
          kinds = Array(kinds) & %w(review mail_review)
          keys = kinds.map { |kind| effect_key(report, inbound_email, kind) }
          tasks = report.obligations.open.where(source: inbound_email, kind: kinds)
          tasks = tasks.where(effect_key: keys) if producer_only
          tasks.each do |obligation|
            ReportObligations.fulfil!(obligation, by:)
          end
        end

        def self.effect_key(report, inbound_email, kind)
          "mail:#{inbound_email.id}:case:#{report.id}:#{kind}"
        end
      end
    end
  end
end
