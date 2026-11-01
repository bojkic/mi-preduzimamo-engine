# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # LFBN review queue for organization-submitted projects, non-cash needs,
      # and the final recognition step for confirmed contribution offers.
      class CommunityContributionsController < Decidim::Bih::Admin::ApplicationController
        QUEUE_PAGE_SIZE = 25

        before_action -> { require_bih_permission!(:community_contributions_read) }, only: :index
        before_action -> { require_bih_permission!(:community_project_review) },
                      only: [:approve_project, :reject_project, :request_project_changes]
        before_action -> { require_bih_permission!(:contribution_need_review) }, only: [:approve_need, :reject_need]
        before_action -> { require_bih_permission!(:contribution_offer_manage) }, only: :manage_offer

        def index
          load_queues
        end

        def approve_project
          submission = project_submission_scope.find_by(id: params[:id])
          result = Decidim::Bih::ApprovePartnerProjectSubmission.call(
            submission,
            reviewer: current_user,
            campaign_key: params[:campaign_key]
          )
          audit_review!(
            "community_project_approved",
            permission: "community_project_review",
            resource: submission,
            result:,
            metadata: { campaign_key_present: params[:campaign_key].to_s.strip.present? }
          )
          if [:ok, :already].include?(result)
            redirect_with_result(result, :project_approved, anchor: "community-project-submissions")
          else
            render_project_approval_error(submission, result)
          end
        rescue ActiveRecord::RecordInvalid
          render_project_approval_error(submission, :invalid)
        end

        def reject_project
          submission = project_submission_scope.find_by(id: params[:id])
          result = Decidim::Bih::RejectPartnerProjectSubmission.call(
            submission,
            reviewer: current_user,
            reason: params[:rejection_reason]
          )
          audit_review!(
            "community_project_rejected",
            permission: "community_project_review",
            resource: submission,
            result:,
            metadata: { reason_present: params[:rejection_reason].to_s.strip.present? }
          )
          redirect_with_result(result, :project_rejected, anchor: "community-project-submissions")
        end

        def request_project_changes
          submission = project_submission_scope.find_by(id: params[:id])
          result = Decidim::Bih::RequestPartnerProjectChanges.call(
            submission,
            reviewer: current_user,
            reason: params[:rejection_reason]
          )
          audit_review!(
            "community_project_changes_requested",
            permission: "community_project_review",
            resource: submission,
            result:,
            metadata: { reason_present: params[:rejection_reason].to_s.strip.present? }
          )
          redirect_with_result(result, :project_changes_requested, anchor: "community-project-submissions")
        end

        def approve_need
          need = contribution_need_scope.find_by(id: params[:id])
          result = Decidim::Bih::ApproveContributionNeed.call(need, reviewer: current_user)
          audit_review!(
            "contribution_need_approved",
            permission: "contribution_need_review",
            resource: need,
            result:
          )
          redirect_with_result(result, :need_approved, anchor: "community-contribution-needs")
        end

        def reject_need
          need = contribution_need_scope.find_by(id: params[:id])
          result = Decidim::Bih::RejectContributionNeed.call(
            need,
            reviewer: current_user,
            reason: params[:rejection_reason]
          )
          audit_review!(
            "contribution_need_rejected",
            permission: "contribution_need_review",
            resource: need,
            result:,
            metadata: { reason_present: params[:rejection_reason].to_s.strip.present? }
          )
          redirect_with_result(result, :need_rejected, anchor: "community-contribution-needs")
        end

        def manage_offer
          offer = contribution_offer_scope.find_by(id: params[:id])
          action = params[:decision].to_s
          result = Decidim::Bih::ManageContributionOffer.call(
            offer:,
            actor: current_user,
            action:,
            reason: params[:reason]
          )
          audit_review!(
            "contribution_offer_#{action}",
            permission: "contribution_offer_manage",
            resource: offer,
            result:,
            metadata: { action: }
          )
          redirect_with_result(result, :offer_updated, anchor: "community-contribution-offers")
        end

        private

        def project_submission_scope
          Decidim::Bih::PartnerProjectSubmission.where(organization: current_organization)
        end

        def contribution_need_scope
          Decidim::Bih::ContributionNeed.where(organization: current_organization)
        end

        def contribution_offer_scope
          Decidim::Bih::ContributionOffer.where(organization: current_organization)
        end

        def audit_review!(event_type, permission:, resource:, result:, metadata: {})
          return unless [:ok, :already].include?(result)

          audit_operator_action!(
            event_type,
            permission:,
            resource:,
            metadata: metadata.merge(already: result == :already)
          )
        end

        def redirect_with_result(result, success_key, anchor:)
          successful = [:ok, :already].include?(result)
          key = if successful
                  success_key
                elsif result == :campaign_unverified
                  :campaign_unverified
                else
                  :action_failed
                end
          flash[successful ? :notice : :alert] = t("decidim.bih.admin.community_contributions.flash.#{key}")
          if successful
            key, scope = case anchor
                         when "community-project-submissions" then ["projects_page", project_submission_scope.pending_review]
                         when "community-contribution-needs" then ["needs_page", contribution_need_scope.where(review_status: "pending")]
                         when "community-contribution-offers" then ["offers_page", contribution_offer_scope.where(status: "confirmed", recognized_at: nil)]
                         end
            queue_context.clamp_to_count(key, count: scope.count, per: QUEUE_PAGE_SIZE) if key
          end
          redirect_to community_contributions_path(queue_context.to_h.merge(anchor:))
        end

        def load_queues(focus_submission: nil)
          @queue_page_params = queue_context.to_h
          scope = project_submission_scope.pending_review.includes(:partner_profile, :representative)
          scope = scope.where(id: focus_submission.id) if focus_submission
          @project_submissions = scope.order(submitted_at: :asc, created_at: :asc)
                                      .page(focus_submission ? 1 : queue_context.page(:projects_page)).per(QUEUE_PAGE_SIZE)
          @contribution_needs = contribution_need_scope.where(review_status: "pending")
                                                 .includes(:partner_profile, :author, :project)
                                                 .order(created_at: :asc)
                                                 .page(queue_context.page(:needs_page)).per(QUEUE_PAGE_SIZE)
          @contribution_offers = contribution_offer_scope.where(status: "confirmed", recognized_at: nil)
                                                   .includes(:contributor, :partner_profile,
                                                             contribution_need: [:partner_profile, :project])
                                                   .order(created_at: :asc)
                                                   .page(queue_context.page(:offers_page)).per(QUEUE_PAGE_SIZE)
        end

        def render_project_approval_error(submission, result)
          return redirect_with_result(result, :project_approved, anchor: "community-project-submissions") unless submission && bih_allowed?(:community_contributions_read)

          @campaign_key_input = params[:campaign_key].to_s
          @failed_project_submission_id = submission&.id
          flash.now[:alert] = t("decidim.bih.admin.community_contributions.flash.#{result == :campaign_unverified ? :campaign_unverified : :action_failed}")
          load_queues(focus_submission: submission)
          render :index, status: :unprocessable_entity
        end

        helper_method def queue_total(collection)
          collection.respond_to?(:total_count) ? collection.total_count : collection.size
        end

        def queue_context
          @queue_context ||= Decidim::Bih::Admin::CommunityQueueContext.new(params)
        end
      end
    end
  end
end
