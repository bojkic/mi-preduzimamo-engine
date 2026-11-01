# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class VolunteeringController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:volunteering_roster_read) }, only: [:index, :show, :attendance]
        before_action -> { require_bih_permission!(:volunteering_opportunity_review) }, only: [:publish_opportunity, :return_opportunity]
        before_action -> { require_bih_permission!(:volunteering_partner_confirm) }, only: [:confirm_partner]
        before_action -> { require_bih_permission!(:volunteering_attendance_confirm) }, only: [:confirm_attendance, :confirm_attendance_token]
        before_action -> { require_bih_permission!(:volunteering_series_manage) }, only: [:manage_opportunity, :update_series, :cancel_series]
        before_action -> { require_bih_permission!(:volunteering_application_review) }, only: [:decide_application]

        before_action -> { require_bih_permission!(:organization_spending_decide) }, only: [:retry_bonus]

        def index
          @roster = Decidim::Bih::Admin::VolunteeringRoster.new(current_organization, filters: filter_params)
        end

        def show
          @opportunity = scoped_opportunities.find(params[:id])
          @terms = proposal_scope(@opportunity)
                   .order(:starts_at, :id).includes(signups: :user, logs: :user).to_a
          @terms = [@opportunity] if @terms.empty?
          @bonus_commitments = Decidim::Bih::Goodwill::VolunteerBonusCommitment
            .where(organization: current_organization, opportunity: @terms).includes(:log).index_by(&:volunteer_log_id)
          @term_previews = @terms.index_with do |term|
            Decidim::Bih::Admin::VolunteerOpportunityManagement.new(
              organization: current_organization, opportunity: term, actor: current_user,
              action: "edit", scope: "term"
            ).preview
          end
          @series_previews = @terms.select(&:series?).index_with do |term|
            Decidim::Bih::Admin::VolunteerOpportunityManagement.new(
              organization: current_organization, opportunity: term, actor: current_user,
              action: "postpone", scope: "future"
            ).preview
          end
        end

        def retry_bonus
          log = Decidim::Bih::VolunteerLog.where(organization: current_organization).find_by(id: params[:id])
          if log && params[:reason].to_s.strip.present? && params[:reason].to_s.length <= 1_000 &&
             bih_allowed?(:organization_spending_decide, resource: log.opportunity)
            Decidim::Bih::Goodwill::VolunteerOrgBonus.retry(log, actor: current_user, reason: params[:reason])
            flash[:notice] = t("decidim.bih.admin.volunteering.workspace.bonus_checked")
          else
            flash[:alert] = t("decidim.bih.admin.volunteering.workspace.bonus_retry_failed")
          end
          redirect_to(log ? detail_path(log.opportunity) : admin_bih_volunteering_path)
        end

        def publish_opportunity
          opportunity = scoped_opportunities.find_by(id: params[:id])
          unless opportunity
            return redirect_to admin_bih_volunteering_path(tab: "opportunities"),
                               alert: t("decidim.bih.admin.goodwill.approve_volunteer_opportunity.approve_failed")
          end

          group = proposal_scope(opportunity)
          published = []
          valid = true
          Decidim::Bih::VolunteerOpportunity.transaction do
            group.where(review_status: "pending").order(:id).lock.each do |term|
              result = Decidim::Bih::ApproveVolunteerOpportunity.call(
                term, reviewer: current_user, confirm_partner: params[:confirm_partner] == "1", notify: false
              )
              unless result == :ok
                valid = false
                raise ActiveRecord::Rollback
              end
              published << term
            end
          end
          if valid && published.any?
            audit_operator_action!("volunteer_opportunity_approved", permission: "volunteering_opportunity_review",
                                   resource: opportunity, metadata: { term_ids: published.map(&:id),
                                                                      partner_confirmed: params[:confirm_partner] == "1" })
            published.map(&:author).compact.uniq.each do |author|
              Decidim::Bih::VolunteerNotifications.publish(
                user: author, kind: "opportunity", status: "approved", title: opportunity.title
              )
            end
            flash[:notice] = t("decidim.bih.admin.goodwill.approve_volunteer_opportunity.approved")
          else
            flash[:alert] = t("decidim.bih.admin.goodwill.approve_volunteer_opportunity.approve_failed")
          end
          redirect_to detail_path(opportunity)
        end

        def return_opportunity
          opportunity = scoped_opportunities.find_by(id: params[:id])
          reason = params[:reason].to_s.strip
          changed = []
          if opportunity && reason.present? && reason.length <= 1_000
            group = proposal_scope(opportunity)
            Decidim::Bih::VolunteerOpportunity.transaction do
              group.where(review_status: "pending").order(:id).lock.each do |term|
                term.update!(review_status: "needs_revision", active: false, rejection_reason: reason,
                             reviewer: current_user, reviewed_at: Time.current)
                changed << term.id
              end
            end
          end
          if changed.any?
            audit_operator_action!("volunteer_opportunity_returned", permission: "volunteering_opportunity_review",
                                   resource: opportunity, metadata: { reason: reason, term_ids: changed })
            @opportunity_author = opportunity.author
            Decidim::Bih::VolunteerNotifications.publish(
              user: @opportunity_author, kind: "opportunity", status: "needs_revision",
              title: opportunity.title, reason:
            )
            flash[:notice] = t("decidim.bih.admin.volunteering.return_opportunity.success")
          else
            flash[:alert] = t("decidim.bih.admin.volunteering.return_opportunity.invalid")
          end
          redirect_to detail_path(opportunity)
        end

        def decide_application
          signup = Decidim::Bih::VolunteerSignup.where(organization: current_organization).find_by(id: params[:id])
          result = Decidim::Bih::ReviewVolunteerApplication.call(
            signup, reviewer: current_user, decision: params[:decision], reason: params[:reason]
          )
          if %i(approved_place approved_waitlist rejected closed).include?(result.status)
            flash[:notice] = t("decidim.bih.admin.volunteering.decide_application.#{result.status}")
          else
            flash[:alert] = t("decidim.bih.admin.volunteering.decide_application.invalid")
          end
          redirect_to detail_path(result.signup&.opportunity || signup&.opportunity, tab: "applications")
        end

        def manage_opportunity
          opportunity = scoped_opportunities.find(params[:id])
          manager = Decidim::Bih::Admin::VolunteerOpportunityManagement.new(
            organization: current_organization, opportunity:, actor: current_user,
            action: params[:operation], scope: params[:scope], attributes: management_params,
            reason: params[:reason]
          )
          result = manager.call(expected_token: params[:preview_token])
          if result.status == :updated
            audit_operator_action!("volunteer_opportunity_managed", permission: "volunteering_series_manage",
                                   resource: opportunity, metadata: { operation: params[:operation], scope: params[:scope],
                                                                      term_ids: result.terms.map(&:id), reason_present: params[:reason].present?,
                                                                      changes: result.changes,
                                                                      preview: { going: result.preview.going, pending: result.preview.pending,
                                                                                 attendance: result.preview.attendance, logs: result.preview.logs } })
            flash[:notice] = t("decidim.bih.admin.volunteering.manage_opportunity.updated")
          else
            flash[:alert] = t("decidim.bih.admin.volunteering.manage_opportunity.invalid", errors: result.errors.join(", "))
          end
          redirect_to detail_path(result.terms.first || opportunity)
        end

        def confirm_partner
          opportunity = scoped_opportunities.find_by(id: params[:id])
          return redirect_to(admin_bih_volunteering_path, alert: t(".not_found")) unless opportunity

          result = opportunity.with_lock do
            next :unavailable unless opportunity.partner_name.present? && opportunity.active? &&
                                     opportunity.review_status == "approved" && !opportunity.cancelled?
            next :already if opportunity.partner_confirmed?

            opportunity.update!(partner_confirmed_at: Time.current, partner_confirmer: current_user)
            audit_operator_action!("volunteering_partner_confirmed", permission: "volunteering_partner_confirm",
                                   resource: opportunity, metadata: { partner_name_present: true })
            :confirmed
          end
          flash[result == :unavailable ? :alert : :notice] = t(".#{result}")
          redirect_to detail_path(opportunity)
        end

        def attendance
          @signup = signup_from_token
          unless @signup
            flash[:alert] = t(".invalid")
            return redirect_to admin_bih_volunteering_path(tab: "applications")
          end
          @opportunity = @signup.opportunity
        end

        def confirm_attendance
          signup = Decidim::Bih::VolunteerSignup.where(organization: current_organization).find_by(id: params[:id])
          confirm_signup_attendance(signup, source: "operator")
        end

        def confirm_attendance_token
          confirm_signup_attendance(signup_from_token, source: "qr")
        end

        # Old POST URLs still execute the operator's requested command through
        # the same guarded management service used by the detail screen.
        def update_series
          legacy_series_action(cancel: false)
        end

        def cancel_series
          legacy_series_action(cancel: true)
        end

        private

        def scoped_opportunities
          Decidim::Bih::VolunteerOpportunity.where(organization: current_organization)
        end

        def proposal_scope(opportunity)
          if opportunity.proposal_identity.present?
            scoped_opportunities.where(proposal_identity: opportunity.proposal_identity)
          elsif opportunity.series_key.present?
            scoped_opportunities.where(series_key: opportunity.series_key)
          else
            scoped_opportunities.where(id: opportunity.id)
          end
        end

        def detail_path(opportunity, tab: nil)
          context = filter_params.symbolize_keys
          context[:tab] = tab if tab.present?
          return admin_bih_volunteering_path(context.reverse_merge(tab: "opportunities")) unless opportunity

          admin_bih_volunteer_opportunity_path({ id: opportunity.id }.merge(context))
        end

        def filter_params
          params.permit(:tab, :status, :task, :q, :page, :date, :category, :komsiluk_id).to_h
        end

        def management_params
          params.permit(:title, :meeting_point, :capacity, :category, :requirements,
                        :starts_at, :ends_at, :signup_deadline_at, :shift_days).to_h
        end

        def signup_from_token
          Decidim::Bih::VolunteerAttendanceToken.resolve(params[:token], organization: current_organization)
        end

        def confirm_signup_attendance(signup, source:)
          date = begin
            Date.iso8601(params[:work_date].to_s)
          rescue Date::Error
            nil
          end
          result = Decidim::Bih::ConfirmVolunteerAttendance.call(
            signup, confirmer: current_user, source:, work_date: date,
            status: params[:attendance_status].presence || "confirmed"
          )
          redirect_to detail_path(result.signup&.opportunity || signup&.opportunity, tab: "applications"),
                      notice: t("decidim.bih.admin.volunteering.confirm_attendance.#{result.status}",
                                default: t("decidim.bih.admin.volunteering.confirm_attendance.invalid"))
        end

        def legacy_series_action(cancel:)
          opportunity = scoped_opportunities.where(series_key: params[:series_key]).order(:starts_at, :id).first
          unless opportunity
            redirect_to admin_bih_volunteering_path(tab: "opportunities"), alert: t("decidim.bih.admin.volunteering.manage_opportunity.invalid", errors: "series_not_found")
            return
          end

          operation = cancel ? "cancel" : "edit"
          manager = Decidim::Bih::Admin::VolunteerOpportunityManagement.new(
            organization: current_organization, opportunity:, actor: current_user,
            action: operation, scope: "future", attributes: series_update_params,
            reason: params[:cancellation_reason]
          )
          result = manager.call(expected_token: manager.preview.token)
          if result.status == :updated
            audit_operator_action!("volunteer_opportunity_managed", permission: "volunteering_series_manage",
                                   resource: opportunity, metadata: { operation:, scope: "future", legacy_route: true,
                                                                      changes: result.changes, reason: params[:cancellation_reason] })
            flash[:notice] = t("decidim.bih.admin.volunteering.manage_opportunity.updated")
          else
            flash[:alert] = t("decidim.bih.admin.volunteering.manage_opportunity.invalid", errors: result.errors.join(", "))
          end
          redirect_to detail_path(opportunity)
        end

        def series_update_params
          params.permit(:title, :meeting_point, :capacity, :category, :requirements).to_h
        end
      end
    end
  end
end
