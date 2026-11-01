# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Admin surface for the citizen report lifecycle — lets operators triage
      # reports, move them through statuses, and retry failed Sistem 48 forwarding,
      # without needing console access.
      #
      # Permission model: mirrors GoodwillController exactly — gated on
      # current_user.admin? via ApplicationController#ensure_global_admin!.
      # No reporter PII appears in the index list; the reference column links to
      # the public report status page.
      class ReportsController < Decidim::Bih::Admin::ApplicationController
        include Decidim::Bih::Admin::ScopedFinder

        before_action -> { require_bih_permission!(:reports_read) }
        before_action -> { require_bih_permission!(:reports_update_status) }, only: [:update_status]
        before_action -> { require_bih_permission!(:reports_internal_note) }, only: [:update_internal_note]
        before_action -> { require_bih_permission!(:reports_mark_duplicate) }, only: [:mark_duplicate, :clear_duplicate]
        before_action -> { require_bih_permission!(:reports_retry_forwarding) }, only: [:retry_forwarding]

        # The queue is paginated rather than cut off at a fixed ceiling, which
        # used to hide everything past the 50th report with no way to reach it.
        PER_PAGE = 25
        # An operator pasting a whole sentence should still get a bounded query;
        # ReportSearchText caps the token count, this caps the raw input.
        MAX_QUERY_LENGTH = 120
        # Allowlisted heatmap windows (days) the operator can switch between.
        HEATMAP_WINDOWS = [30, 90, 365].freeze
        DEFAULT_HEATMAP_WINDOW = 90
        AGE_FILTERS = %w(recent_7 older_than_7 older_than_30 older_than_90).freeze
        ATTENTION_FILTERS = Decidim::Bih::Admin::ReportTriageSummary::BUCKETS
        FORWARDING_SLA_DAYS = Decidim::Bih::Admin::ReportTriageSummary::FORWARDING_SLA_DAYS

        # GET /admin/bih/reports
        # Filterable by free-text search, status, MZ and age, in
        # any combination. Ordering is by search relevance when `q` is present
        # and needs-attention-first (failed forwarding or stuck primljeno)
        # otherwise. Paginated.
        def index
          if params[:batch] == "1"
            context = ReportQueueContext.new(organization: current_organization, actor: current_user, params: params.permit(*ReportQueueContext::KEYS))
            redirect_to admin_bih_report_review_batch_path(return_to: context.path)
            return
          end
          response.cache_control.replace(no_store: true, private: true)
          if params[:tab] == "insights"
            @metrics = ReportReviewMetrics.new(organization: current_organization).call
            @sla_summary = report_triage_summary.rows
            @heatmap_window = heatmap_window
            @heatmap = ReportHeatmap.new(organization: current_organization, since: @heatmap_window.days.ago).call
            return
          end
          load_index_filters
          base = filtered_report_scope

          @work_queue = ReportWorkQueue.new(organization: current_organization)
          default_view = params[:status].present? || params[:case_state].present? || params[:attention].present? ? "all" : "review"
          @work_view = params[:view].presence_in(ReportWorkQueue::VIEWS) || default_view
          base = @work_queue.search(@work_queue.scope(@work_view, base: base), params[:q])
          @queue_counts = @work_queue.counts
          @total_count = base.count
          @page_count = [(@total_count.to_f / ReportWorkQueue::PAGE_SIZE).ceil, 1].max
          @page = params[:page].to_i.clamp(1, @page_count)
          @reports = @work_queue.ordered(base).includes(:duplicate_of, :assigned_to, :dispatches, :report_collection)
                                .offset((@page - 1) * ReportWorkQueue::PAGE_SIZE).limit(ReportWorkQueue::PAGE_SIZE)
          @mz_names = mz_names_for(@reports)
          if @work_view == "planning"
            @collections = ReportCollection.where(organization: current_organization, state: %w(collecting ready))
                                           .includes(:assigned_to).order(:review_due_at, :id)
          end
        end

        # GET /admin/bih/reports/:reference
        # Detail view for one report's operator-safe event trail. The event log
        # is append-only and stores no report description/contact/address text.
        def show
          @report = find_report!
          return unless @report

          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
          if params[:photo_message_id].present?
            photo = @report.case_messages.find(params[:photo_message_id]).photo
            raise ActiveRecord::RecordNotFound unless photo.attached?

            return send_data ReportPrivateStorage.download!(photo.blob), type: photo.content_type, disposition: "attachment",
                                                                         filename: "#{@report.reference}-photo#{File.extname(photo.filename.to_s)}"
          end
          @queue_context = ReportQueueContext.from_path(params[:return_to], organization: current_organization, actor: current_user)
          @events = @report.events.includes(:actor).chronological
        end

        # Compatibility redirects for old tabs. All writes use ReportDecision.
        def update_status = reopen_review

        def update_internal_note = reopen_review

        def mark_duplicate = reopen_review

        def clear_duplicate = reopen_review

        def retry_forwarding = reopen_review

        private

        def load_index_filters
          @query_filter = params[:q].to_s.strip.first(MAX_QUERY_LENGTH).presence
          @status_filter = allowed_filter(:status, ReportStatusPresenter.filter_statuses)
          @age_filter = allowed_filter(:age, AGE_FILTERS)
          @attention_filter = allowed_filter(:attention, ATTENTION_FILTERS)
          @mz_options = mz_options
          @mz_filter = allowed_filter(:mz_slug, @mz_options.map(&:slug))
        end

        def allowed_filter(param_name, allowed_values)
          value = params[param_name].to_s.presence
          allowed_values.include?(value) ? value : nil
        end

        def filtered_report_scope(apply_attention: true)
          ReportQueueContext.new(organization: current_organization, actor: current_user,
                                 params: params.permit(*ReportQueueContext::KEYS)).base_scope(apply_attention:)
        end

        def heatmap_window
          requested = params[:heatmap_days].to_i
          HEATMAP_WINDOWS.include?(requested) ? requested : DEFAULT_HEATMAP_WINDOW
        end

        def report_triage_summary
          @report_triage_summary ||= Decidim::Bih::Admin::ReportTriageSummary.new(organization: current_organization)
        end

        def mz_options
          Decidim::Bih::LocalArea
            .mz
            .where(organization: current_organization)
            .order(:slug)
            .to_a
        end

        def mz_names_for(reports)
          mz_names_for_slugs(reports.map(&:mz_slug))
        end

        def mz_names_for_slugs(slugs)
          slugs = slugs.compact_blank.uniq
          return {} if slugs.empty?

          Decidim::Bih::LocalArea
            .mz
            .where(organization: current_organization, slug: slugs)
            .index_by(&:slug)
            .transform_values(&:translated_name)
        end

        def find_report!
          # Absolute key (not the per-action relative ".not_found"): the helper
          # now lives in a shared concern, so a relative lookup would resolve
          # against the concern, not the calling action. All three actions used
          # the same string ("Prijava nije pronađena."), so this is identical.
          find_scoped!(
            Decidim::Bih::Report.where(organization: current_organization),
            reference: params[:reference],
            redirect_to: admin_bih_reports_path,
            flash_key: "decidim.bih.admin.reports.index.not_found"
          )
        end

        def reopen_review
          report = find_report!
          return unless report

          context = ReportQueueContext.from_path(params[:return_to], organization: current_organization, actor: current_user)
          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
          redirect_to admin_bih_report_path(reference: report.reference, return_to: context.path), status: :see_other,
                                                                                                   alert: t("decidim.bih.review_workspace.legacy_form")
        end
      end
    end
  end
end
