# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Old tabs/bookmarks must reopen the current versioned workspace. Their
      # payloads lack an actor-bound decision version and may never mutate data.
      class ReportCasesController < ApplicationController
        before_action -> { require_bih_permission!(:reports_read) }
        before_action -> { require_bih_permission!(:reports_update_status) }, only: [:update, :message, :location, :plan, :unplan]
        before_action -> { require_bih_permission!(:reports_retry_forwarding) }, only: [:preview, :forward, :record_external]

        def update = reopen_review

        def message = reopen_review

        def location = reopen_review

        def plan = reopen_review

        def unplan = reopen_review

        def preview = reopen_review

        def forward = reopen_review

        def record_external = reopen_review

        private

        def reopen_review
          report = Report.find_by!(organization: current_organization, reference: params[:reference])
          context = ReportQueueContext.from_path(params[:return_to], organization: current_organization, actor: current_user)
          response.cache_control.replace(no_store: true, private: true)
          response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
          response.set_header("X-Robots-Tag", "noindex, nofollow")
          redirect_to admin_bih_report_path(reference: report.reference, return_to: context.path), status: :see_other,
                                                                                                   alert: t("decidim.bih.review_workspace.legacy_form")
        end
      end
    end
  end
end
