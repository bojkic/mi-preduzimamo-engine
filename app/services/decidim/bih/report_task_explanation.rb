# frozen_string_literal: true

module Decidim
  module Bih
    # Plain-language "what is this task and what do I do" for the case page.
    # Owner feedback 2026-10-06: a bare task label did not say what had to be
    # resolved (e.g. that the police question was still open).
    module ReportTaskExplanation
      AUTO_CLOSED = %w(review mail_review).freeze

      module_function

      def call(task)
        reason = task.metadata["reason"].presence || task.metadata["assessment_reason"].presence
        values = { quote: task.metadata["quote"].to_s.strip.presence || "—", phone: task.metadata["traffic_police_phone"].presence || "—",
                   subject: "—", date: "—" }
        if task.source.is_a?(InboundEmail)
          values[:subject] = (task.source.subject.to_s.strip.presence || "—").first(160)
          values[:date] = I18n.l(task.source.internal_date, format: :short)
        end
        key = reason && I18n.exists?("decidim.bih.report_tasks.explain.#{reason}") ? "explain.#{reason}" : "kinds.#{task.kind}"
        I18n.t("decidim.bih.report_tasks.#{key}", **values, default: "")
      rescue StandardError
        I18n.t("decidim.bih.report_tasks.kinds.#{task.kind}", default: "")
      end

      def closes_automatically?(task) = AUTO_CLOSED.include?(task.kind)
    end
  end
end
