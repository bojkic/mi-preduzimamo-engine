# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # PII-safe internal analytics exports for host operators.
      class AnalyticsController < Decidim::Bih::Admin::ApplicationController
        DATASETS = Decidim::Bih::Admin::AnalyticsSummary::DATASETS
        WORKFLOW_TABS = %w(exports mi_bot_review examples trends previews chat_health metrics).freeze
        DEFAULT_WORKFLOW_TAB = "exports"

        before_action -> { require_bih_permission!(:analytics_read) }, only: [:index]
        before_action :require_mi_bot_examples_permission!, only: [:index]
        before_action -> { require_bih_permission!(:analytics_export) }, only: [:export]

        def index
          @analytics_workflow_tabs = WORKFLOW_TABS
          @active_analytics_tab = active_workflow_tab
          @summary = analytics_summary
          @overview = @summary.overview
          @registration_funnel = @summary.registration_funnel if @active_analytics_tab == "exports"
          @mi_bot_answer_review_rows = @active_analytics_tab == "mi_bot_review" ? @summary.mi_bot_answer_review_queue : []
          @mi_bot_review_comparison_rows = @active_analytics_tab == "trends" ? @summary.rows_for("mi_bot_review_comparison").first(8) : []
          @mi_bot_answer_review_examples = @active_analytics_tab == "examples" ? @summary.mi_bot_answer_review_examples : []
          @concierge_metrics = @active_analytics_tab == "metrics" ? @summary.concierge_metrics : nil
          @chat_health = @active_analytics_tab == "chat_health" ? @summary.chat_health(period_days: chat_health_period) : nil
        end

        def export
          dataset = params[:dataset].to_s
          unless DATASETS.include?(dataset)
            flash[:alert] = t("decidim.bih.admin.analytics.export.unknown_dataset")
            return redirect_to admin_bih_analytics_path
          end

          audit_operator_action!(
            "analytics_exported",
            permission: "analytics_export",
            metadata: { dataset: }
          )

          send_data(
            analytics_summary.csv_for(dataset),
            type: "text/csv; charset=utf-8",
            disposition: "attachment",
            filename: "bih-#{dataset}-analytics-#{Time.current.utc.strftime("%Y%m%d%H%M%S")}.csv"
          )
        end

        private

        def analytics_summary
          Decidim::Bih::Admin::AnalyticsSummary.new(organization: current_organization,
                                                    metric_filters: { period: params[:period], cohort: params[:cohort],
                                                                      traffic: params[:traffic] })
        end

        def chat_health_period
          Decidim::Bih::Admin::ChatHealthSummary.period(params[:period])
        end

        def active_workflow_tab
          requested = params[:tab].to_s
          WORKFLOW_TABS.include?(requested) ? requested : DEFAULT_WORKFLOW_TAB
        end

        def require_mi_bot_examples_permission!
          return unless params[:tab].to_s == "examples"

          require_bih_permission!(:mi_bot_examples_read)
        end
      end
    end
  end
end
