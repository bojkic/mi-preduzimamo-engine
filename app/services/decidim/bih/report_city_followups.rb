# frozen_string_literal: true

module Decidim
  module Bih
    # Owner decision 2026-10-05: when the City has not answered within the
    # 21-day clock, the platform sends one polite follow-up in the same thread.
    # Owner decision 2026-10-30: the follow-up repeats each time a City clock
    # runs out unanswered (one per clock); weekdays only; capped per run.
    # Cases where the City already wrote back get a staff task instead.
    module ReportCityFollowups
      DAILY_LIMIT = 10
      EVENT = "case_city_followup_automatic"

      module_function

      def run!(organization: nil, now: Time.current)
        return [] if now.in_time_zone("Europe/Sarajevo").on_weekend?

        hand_answered_to_staff!(organization:, now:)
        sent = []
        due_tasks(organization:, now:).each do |task|
          break if sent.size >= DAILY_LIMIT

          dispatch = send_followup!(task)
          sent << dispatch if dispatch
        rescue ReportDispatching::Invalid, Decidim::ActionForbidden, ActiveRecord::RecordInvalid => e
          Rails.logger.info("[ReportCityFollowups] report=#{task.report_id} skipped=#{e.class}")
        end
        sent
      end

      def overdue_tasks(organization:, now:)
        scope = ReportObligation.open.where(kind: "city_response", actor: "city").where(due_at: ...now).order(:due_at, :id)
        scope = scope.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id }) if organization
        scope.includes(:report).reject { |task| ReportWorkQueue.closed?(task.report) }
      end

      def due_tasks(organization:, now:)
        overdue_tasks(organization:, now:).select do |task|
          report = task.report
          task.metadata["inbound_email_id"].blank? && report.review_state == "validated" && report.forwarded_at.present? &&
            !followed_up?(task) && !report.dispatches.exists?(state: %w(queued sending unknown))
        end
      end

      # The City answered (e.g. "the service was asked to remove it") but the
      # clock ran out without a final answer: a generic reminder would ignore
      # their reply, so staff decide (BR-2026-0029 sat overdue unseen).
      def hand_answered_to_staff!(organization:, now:)
        overdue_tasks(organization:, now:).each do |task|
          # Pending review or a citizen question already puts the case with someone.
          next if task.metadata["inbound_email_id"].blank? || task.report.review_state != "validated"

          ReportObligations.open!(task.report, kind: "review", source: task, effect_key: "city-overdue-after-reply:#{task.id}",
                                               metadata: { reason: "city_overdue_after_reply", obligation_id: task.id })
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.info("[ReportCityFollowups] report=#{task.report_id} staff_task_skipped=#{e.class}")
        end
      end

      def followed_up?(task)
        task.report.events.where(event_type: EVENT).exists?(["metadata ->> 'obligation_id' = ?", task.id.to_s])
      end

      def send_followup!(task)
        report = task.report
        actor = actor_for(report)
        return unless actor

        text = message_text(report)
        dispatch = ReportDispatching.queue!(report:, actor:, digest: ReportCaseWorkflow.digest(report), kind: "followup", text:)
        report.record_event!(EVENT, source: "system", metadata: { dispatch_id: dispatch.id, obligation_id: task.id,
                                                                  days_waiting: ((Time.current - report.forwarded_at) / 1.day).floor })
        dispatch
      end

      # The approval is the owner's standing decision; record it under the
      # case owner (or an organization admin) who holds the send permission.
      def actor_for(report)
        staff = ReportCaseWorkflow.staff(report.organization)
        candidates = [staff.find_by(id: report.assigned_to_id), *staff.where(admin: true).order(:id).to_a].compact
        candidates.find { |user| OperatorAuthorization.allowed?(user, :reports_retry_forwarding, organization: report.organization) }
      end

      def message_text(report)
        sent_on = report.forwarded_at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y.")
        location = report.address.presence && "Lokacija: #{report.address}.\n\n"
        "Poštovani,\n\n" \
          "Dana #{sent_on} proslijedili smo Vam prijavu građana #{report.reference}.#{previous_followups(report)} Do danas nismo zabilježili odgovor.\n\n" \
          "#{location}" \
          "Molimo Vas da nas obavijestite da li je prijava zaprimljena, ko je zadužen i kada se može očekivati rješavanje. " \
          "Dovoljno je odgovoriti na ovu poruku.\n\n" \
          "Hvala na saradnji,\nLokalna fondacija Bijeljina, platforma MI PRE(D)UZIMAMO!"
      end

      def previous_followups(report)
        dates = report.dispatches.where(kind: "followup", state: "accepted").order(:accepted_at).pluck(:accepted_at).compact
        return "" if dates.empty?

        " Podsjetnik smo poslali #{dates.map { |at| at.in_time_zone("Europe/Sarajevo").strftime("%d.%m.%Y.") }.join(", ")}"
      end
    end
  end
end
