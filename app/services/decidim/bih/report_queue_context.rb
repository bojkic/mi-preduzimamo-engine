# frozen_string_literal: true

module Decidim
  module Bih
    # Shared filtered scope and safe navigation context for the list and decisions.
    class ReportQueueContext
      PATH = "/admin/bih/reports"
      KEYS = %w(batch view q page status mz_slug age attention case_state case_owner).freeze
      attr_reader :params

      def initialize(organization:, actor:, params: {})
        @organization = organization
        @actor = actor
        @params = params.to_h.stringify_keys.slice(*KEYS).select { |_key, value| value.is_a?(String) }.transform_values { |value| value.first(120) }
        @params.delete("attention") if @params["attention"] == "needs_review"
      end

      def self.from_path(value, organization:, actor:)
        uri = URI.parse(value.to_s)
        valid = uri.host.nil? && uri.scheme.nil? && uri.path == PATH && uri.fragment.nil?
        parameters = valid ? Rack::Utils.parse_nested_query(uri.query) : {}
        new(organization:, actor:, params: parameters)
      rescue URI::InvalidURIError, Rack::QueryParser::ParameterTypeError, Rack::QueryParser::InvalidParameterError
        new(organization:, actor:)
      end

      def view
        params["view"].presence_in(ReportWorkQueue::VIEWS) || (%w(status case_state attention).any? { |key| params[key].present? } ? "all" : "review")
      end

      def path(page: nil)
        query = params.merge("view" => view)
        query["page"] = page.to_s if page
        "#{PATH}?#{query.to_query}"
      end

      def base_scope(apply_attention: true)
        scope = Report.where(organization: @organization)
        scope = filter_case(scope)
        scope = ReportStatusPresenter.filter(scope, params["status"].presence_in(ReportStatusPresenter.filter_statuses))
        scope = scope.where(mz_slug: params["mz_slug"]) if params["mz_slug"].present? && LocalArea.mz.exists?(organization: @organization, slug: params["mz_slug"])
        scope = filter_age(scope)
        if apply_attention && params["attention"].presence_in(Admin::ReportTriageSummary::BUCKETS)
          scope = Admin::ReportTriageSummary.new(organization: @organization).scope_for(params["attention"], base_scope: scope)
        end
        scope
      end

      def scope
        queue = ReportWorkQueue.new(organization: @organization)
        queue.ordered(queue.search(queue.scope(view, base: base_scope), params["q"]))
      end

      # Look ahead only one page. Compute before changing the current report so
      # that removing it from a filtered queue cannot shift past its successor.
      def successor(report)
        page = [params["page"].to_i, 1].max
        page = page.clamp(1, [(scope.count.to_f / ReportWorkQueue::PAGE_SIZE).ceil, 1].max)
        references = scope.offset((page - 1) * ReportWorkQueue::PAGE_SIZE).limit(ReportWorkQueue::PAGE_SIZE + 1).pluck(:reference)
        position = references.index(report.reference)
        reference = position ? references[position + 1] : references.first
        reference ? { "reference" => reference, "return_to" => path(page: page) } : nil
      end

      private

      def filter_case(scope)
        if params["case_state"] == "duplicate"
          scope = scope.where.not(duplicate_of_report_id: nil)
        elsif Report::REVIEW_STATES.include?(params["case_state"])
          scope = scope.where(review_state: params["case_state"], duplicate_of_report_id: nil)
        end
        scope = scope.where(assigned_to_id: @actor.id) if params["case_owner"] == "mine"
        scope = scope.where(assigned_to_id: nil) if params["case_owner"] == "unassigned"
        scope
      end

      def filter_age(scope)
        return scope.where(created_at: 7.days.ago..) if params["age"] == "recent_7"

        days = { "older_than_7" => 7, "older_than_30" => 30, "older_than_90" => 90 }[params["age"]]
        days ? scope.where(created_at: ...days.days.ago) : scope
      end
    end
  end
end
