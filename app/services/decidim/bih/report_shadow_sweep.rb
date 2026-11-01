# frozen_string_literal: true

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- explicit independent policy and safety guards

module Decidim
  module Bih
    # A durable, serial shadow backlog. Uses the existing mailbox recovery tick
    # so exhausted daily budgets resume tomorrow without occupying a worker.
    # This stores diagnostics, never executes the proposed case action.
    class ReportShadowSweep
      NAMESPACE = "report_review"
      KEY = "shadow_sweep"
      LEASE = 10.minutes
      def self.start!(organization:, actor:, report_ids:)
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(actor, :reports_update_status, organization:)
        raise ArgumentError, "shadow_required" unless ReportReviewAssistant.case_agent_mode(organization) == "shadow"

        ids = Report.where(organization:, id: report_ids).where.not(status: Report::TERMINAL_STATUSES).where(duplicate_of_report_id: nil).order(:id).pluck(:id)
        organization.with_lock do
          existing = Setting.namespace_for(organization, NAMESPACE)[KEY]
          return existing if existing && existing["state"] == "running"

          value = { "id" => SecureRandom.uuid, "state" => "running", "started_at" => Time.current.utc.iso8601,
                    "actor_id" => actor.id, "prompt_version" => Ai::CaseAgent::PROMPT_VERSION, "pending" => ids, "results" => [] }
          Setting.put(organization, NAMESPACE, KEY, value)
        end
        resume!(organization)
        Setting.namespace_for(organization, NAMESPACE)[KEY]
      end

      def self.resume!(organization)
        row = Setting.find_by(organization:, namespace: NAMESPACE, key: KEY)
        return unless row && ReportReviewAssistant.case_agent_mode(organization) == "shadow"

        enqueue = row.with_lock do
          value = row.value.deep_dup
          next false unless value["state"] == "running"
          next false if value["eligible_at"] && Time.iso8601(value["eligible_at"]) > Time.current
          next false if value["queued_at"] && Time.iso8601(value["queued_at"]) > LEASE.ago

          value["queued_at"] = Time.current.utc.iso8601
          row.update!(value:)
          true
        end
        ReportShadowSweepJob.perform_later(organization.id) if enqueue
      end

      def initialize(organization) = @organization = organization

      def call
        row = Setting.find_by(organization: @organization, namespace: NAMESPACE, key: KEY)
        return unless row && ReportReviewAssistant.case_agent_mode(@organization) == "shadow"

        claim = row.with_lock do
          value = row.value.deep_dup
          next unless value["state"] == "running"
          next if value["eligible_at"] && Time.iso8601(value["eligible_at"]) > Time.current
          next if value["claim_at"] && Time.iso8601(value["claim_at"]) > LEASE.ago

          value["claim"] = SecureRandom.uuid
          value["claim_at"] = Time.current.utc.iso8601
          value["queued_at"] = nil
          row.update!(value:)
          [value["claim"], value["pending"].first, Array(value["retried"])]
        end
        return unless claim

        token, id, retried = claim
        report = Report.find_by(id:, organization: @organization)
        # A transport failure (timeout) gets exactly one more attempt at the
        # end of the backlog; validation failures keep their single repair.
        reasons = ["daily_budget_exceeded"] + (retried.include?(id) ? ["unavailable"] : [])
        retry_filter = ["failure_reason IN (?) OR (state = ? AND updated_at < ?)", reasons, "generating", LEASE.ago]
        retryable = report && report.review_proposals.where(prompt_version: Ai::CaseAgent::PROMPT_VERSION).exists?(retry_filter)
        proposal = ReportReviewAssistant.new.call(report, retry_failed: retryable == true, shadow_only: true) if report && ReportReviewAssistant.eligible?(report)
        row.with_lock do
          value = row.value.deep_dup
          next unless value["claim"] == token

          value.except!("claim", "claim_at", "eligible_at")
          busy = report && !ReportWorkQueue.closed?(report) && !ReportReviewAssistant.eligible?(report)
          if proposal&.state == "generating" || busy
            value["eligible_at"] = 1.minute.from_now.utc.iso8601
          elsif proposal&.failure_reason == "daily_budget_exceeded"
            value["eligible_at"] = (Time.current.utc.to_date + 1).to_time.utc.iso8601
          elsif proposal&.failure_reason == "unavailable" && Array(value["retried"]).exclude?(id)
            value["pending"].shift
            value["pending"] << id
            value["retried"] = Array(value["retried"]) + [id]
          else
            value["pending"].shift
            value["results"] << { "report_id" => id, "proposal_id" => proposal&.id,
                                  "state" => proposal&.state || "skipped", "reason" => proposal&.failure_reason, "at" => Time.current.utc.iso8601 }
            value["state"] = "complete" if value["pending"].empty?
            if value["state"] == "complete"
              value["finished_at"] = Time.current.utc.iso8601
              owner = ReportCaseWorkflow.staff(@organization).find_by(id: value["actor_id"])
              if owner
                Decidim::Notification.create!(user: owner, resource: owner,
                                              event_name: "decidim.events.bih.report_shadow_sweep_completed", event_class: ReportShadowSweepCompletedEvent.name,
                                              extra: { "received_as" => "affected_user", "sweep_id" => value["id"], "case_count" => value["results"].length })
              end
            end
          end
          row.update!(value:)
        end
        self.class.resume!(@organization)
      rescue Ai::CaseAgent::Interrupted
        # The worker is shutting down. Hand the claim back instead of holding
        # it for LEASE; the next recovery tick resumes the same report.
        release_claim(row, token) if row && token
        nil
      rescue StandardError => e
        Rails.logger.warn("[ReportShadowSweep] organization=#{@organization.id} error=#{e.class}")
        raise
      end

      private

      def release_claim(row, token)
        row.with_lock do
          value = row.value.deep_dup
          next unless value["claim"] == token

          value.except!("claim", "claim_at")
          value["eligible_at"] = 1.minute.from_now.utc.iso8601
          row.update!(value:)
        end
      end
    end
  end
end

# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
