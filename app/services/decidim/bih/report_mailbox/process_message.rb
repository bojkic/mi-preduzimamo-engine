# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      class ProcessMessage
        def initialize(inbound_email) = @email = inbound_email
        def call
          @claim = claim
          return false unless @claim

          # NO KEY UPDATE also permits report-locked approval effects to take
          # their foreign-key KEY SHARE lock without reversing the lock order.
          @email.with_lock("FOR NO KEY UPDATE") do
            next false unless owns_claim?

            process_claim
          end
        rescue StandardError => error
          recover_claim(error) if @claim
          raise
        end

        private

        def claim
          sql = InboundEmail.sanitize_sql_array([
            "UPDATE #{InboundEmail.quoted_table_name} SET state = ?, locked_at = ?, " \
            "processing_attempts = processing_attempts + 1 WHERE id = ? AND state = ? " \
            "RETURNING locked_at, processing_attempts",
            "processing", Time.current, @email.id, "stored"
          ])
          InboundEmail.connection.exec_query(sql, "Claim inbound mail").first
        end

        def owns_claim?
          @email.state == "processing" && @email.locked_at == @claim.fetch("locked_at") &&
            @email.processing_attempts == @claim.fetch("processing_attempts")
        end

        def recover_claim(error)
          InboundEmail.where(id: @email.id, state: "processing",
                             locked_at: @claim.fetch("locked_at"),
                             processing_attempts: @claim.fetch("processing_attempts"))
                      .update_all(state: "stored", locked_at: nil, review_reason: error.class.name,
                                  updated_at: Time.current)
        end

        def process_claim
          mail = Mail.read_from_string(@email.raw.to_s)
          own_ids = ReportDispatch.joins(:report).where(decidim_bih_reports: { decidim_organization_id: @email.organization.id }).pluck(:message_id)
          classification = Classifier.call(mail, labels: @email.labels, own_message_ids: own_ids)
          @email.update!(classification: classification[:classification], no_auto_response: classification[:no_auto_response])
          candidates = Associator.call(mail, organization: @email.organization, gm_thrid: @email.gm_thrid)
          if @email.history_only
            candidates.each { |candidate| store_link(mail, candidate) }
            candidates.each do |candidate|
              effect(candidate[:report], "history_linked") { candidate[:report].record_event!("city_email_history_linked", source: "background", metadata: { inbound_email_id: @email.id }) }
            end
            finish("history")
            return true
          end
          if %w(draft auto_reply system_notice).include?(@email.classification)
            finish("ignored")
            return true
          end
          if @email.classification == "bounce"
            ids = Array(mail.in_reply_to) + Array(mail.references)
            ReportDispatch.joins(:report).where(decidim_bih_reports: { decidim_organization_id: @email.organization.id }, message_id: ids).each do |dispatch|
              effect(dispatch.report, "bounce:#{dispatch.id}") do
                dispatch.report.record_event!("case_dispatch_bounced", source: "background", metadata: { inbound_email_id: @email.id, dispatch_id: dispatch.id })
                ReportCityReply::StaffNotice.call(report: dispatch.report, inbound_email: @email, reason: "delivery_exception")
              end
            end
            finish("ignored")
            return true
          end
          review = candidates.empty? || @email.message_id_conflict
          candidates.each do |candidate|
            link = store_link(mail, candidate)
            next if %w(outbound_copy staff_sent).include?(@email.classification)
            report = link.report
            if @email.message_id_conflict || link.assurance == "association"
              review = true
              effect(report, "mail_review") { ReportCityReply::StaffNotice.call(report:, inbound_email: @email, reason: "mail_review") }
            elsif link.assurance == "citizen"
              effect(report, "citizen_reply") { CitizenReply.record!(report:, inbound_email: @email, capability: link.capability) }
            elsif terminal?(report)
              effect(report, "terminal_service_notice") { ReportCityReply::StaffNotice.call(report:, inbound_email: @email, reason: "terminal_service_reply") }
            else
              ReportCityReply.record!(report:, inbound_email: @email, link:)
            end
          end
          @email.update!(review_reason: @email.message_id_conflict ? "message_id_conflict" : "association_only") if review
          finish(review ? "review" : "processed")
          true
        end
        def terminal?(report) = %w(rijeseno zatvoreno odbijeno).include?(report.status)
        def effect(report, name, &block) = InboundEmailEffect.once!(inbound_email: @email, report:, effect: name, &block)
        def store_link(mail, candidate)
          link = @email.inbound_email_links.find_or_initialize_by(report: candidate[:report])
          link.assign_attributes(matching_method: candidate[:matching_method], capability: candidate[:capability], assurance: Assurance.call(mail, link: candidate, organization: @email.organization))
          link.save!
          link
        end
        def finish(state) = @email.update!(state:, processed_at: Time.current, locked_at: nil)
      end
    end
  end
end
