# frozen_string_literal: true

module Decidim
  module Bih
    # Public community-support catalog backed by approved partner submissions.
    # Native Budget projects remain an internal storage seam; unrelated
    # participatory-budget projects never enter this catalog merely because they
    # have an Odoo donation mapping.
    class CommunityProjectsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser
      include Decidim::AttachmentsHelper
      helper Decidim::Comments::CommentsHelper

      PRIVATE_HISTORY_LIMIT = 100
      PUBLIC_NEEDS_LIMIT = 100

      def index
        load_public_projects
        load_my_submissions
      end

      def show
        @submission = durable_approved_submissions.find_by(decidim_budgets_project_id: params[:id])
        return redirect_legacy_project unless @submission

        @project = @submission.project
        return render_not_found unless public_project?(@project)

        load_project_participation_context
        load_project_fundraising_context
      end

      def load_project_participation_context
        @partner_profile = @submission.partner_profile
        @project_link = Decidim::Bih::ProjectDonationLink
                        .where(organization: current_organization, project: @project)
                        .order(created_at: :desc)
                        .first
        @partner_participation_enabled = partner_participation_enabled?
        @fundraising_enabled = @partner_participation_enabled && @project_link&.active?
        @contribution_needs = if @partner_participation_enabled
                                Decidim::Bih::ContributionNeed
                                  .approved_open
                                  .where(organization: current_organization, project: @project)
                                  .joins(:partner_profile)
                                  .merge(Decidim::Bih::PartnerProfile.publicly_visible)
                                  .includes(:partner_profile)
                                  .order(needed_by: :asc, created_at: :desc)
                                  .limit(PUBLIC_NEEDS_LIMIT)
                              else
                                Decidim::Bih::ContributionNeed.none
                              end
        load_offer_context
        @volunteer_opportunities = if @partner_participation_enabled
                                     Decidim::Bih::VolunteerOpportunity
                                       .publicly_visible
                                       .where(organization: current_organization, budget_project: @project)
                                       .includes(:partner_profile, :komsiluk)
                                       .order(starts_at: :asc, created_at: :desc)
                                   else
                                     Decidim::Bih::VolunteerOpportunity.none
                                   end
      end

      def load_project_fundraising_context
        mapping = donation_mappings_by_project_id[@project.id]
        @project_totals = project_field(mapping, :totals)
        @donate_url = project_field(mapping, :donate_url).presence || campaign_donate_url(@project_link.campaign_key) if @fundraising_enabled
        @currency_label = donations_provider&.currency_label || "KM"
      end

      private :load_project_participation_context, :load_project_fundraising_context

      def new
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.community_projects.flash.login_required")
          destination = new_community_project_path
          CitizenReturnPath.store(session, organization: current_organization, path: destination)
          return redirect_to decidim.new_user_session_path(redirect_url: destination)
        end

        @partner_profiles = eligible_partner_profiles(user)
        if @partner_profiles.empty?
          flash[:alert] = t("decidim.bih.community_projects.flash.organization_required")
          return redirect_to organizations_path
        end

        @submission = Decidim::Bih::PartnerProjectSubmission.new
      end

      def edit
        user = current_organization_user
        return submission_forbidden unless user

        @submission = editable_submissions(user).find_by(id: params[:id])
        return submission_forbidden unless @submission

        @partner_profiles = [@submission.partner_profile]
        render :new
      end

      def create
        user = current_organization_user
        return submission_forbidden unless user

        @partner_profiles = eligible_partner_profiles(user)
        profile = selected_submission_profile
        return submission_forbidden unless profile

        @submission = build_submission(profile, user)
        handle_submission_result(persist_and_submit(@submission, user), :submitted)
      rescue ActiveRecord::RecordInvalid => e
        render_invalid_submission(e, user)
      end

      def update
        user = current_organization_user
        return submission_forbidden unless user

        @submission = editable_submissions(user).find_by(id: params[:id])
        return submission_forbidden unless @submission

        @partner_profiles = [@submission.partner_profile]
        @submission.assign_attributes(submission_params.except(:partner_profile_id))
        @submission.representative = user
        handle_submission_result(persist_and_submit(@submission, user), :resubmitted)
      rescue ActiveRecord::RecordInvalid => e
        render_invalid_submission(e, user)
      rescue ActiveRecord::StaleObjectError
        flash[:alert] = t("decidim.bih.community_projects.flash.stale_submission")
        redirect_to community_projects_path(anchor: "moji-projekti")
      end

      private

      def load_public_projects
        links = public_project_links
        project_ids = links.map(&:decidim_budgets_project_id)
        submissions = approved_submissions.where(decidim_budgets_project_id: project_ids)
                                          .index_by(&:decidim_budgets_project_id)
        moderated_project_ids = Decidim::Bih::PartnerProjectSubmission
                                .where(organization: current_organization, decidim_budgets_project_id: project_ids)
                                .pluck(:decidim_budgets_project_id)
        mappings = donation_mappings_by_project_id

        @project_rows = links.filter_map { |link| project_row(link, submissions, moderated_project_ids, mappings) }
        @currency_label = donations_provider&.currency_label || "KM"
      end

      def load_my_submissions
        user = current_organization_user
        manageable_profiles = content_partner_profiles(user)
        @my_project_submissions = if manageable_profiles.any?
                                    Decidim::Bih::PartnerProjectSubmission
                                      .where(organization: current_organization, partner_profile: manageable_profiles)
                                      .includes(:partner_profile, :project)
                                      .order(created_at: :desc)
                                      .limit(PRIVATE_HISTORY_LIMIT)
                                  else
                                    Decidim::Bih::PartnerProjectSubmission.none
                                  end
        @can_submit_project = eligible_partner_profiles(user).any?
      end

      def load_offer_context
        user = current_organization_user
        @offering_partner_profile_options = eligible_offering_partner_profiles(user).map do |profile|
          [profile.display_name, profile.id]
        end
        @my_contribution_offers_by_need_id = user ? contribution_offers_by_need(user) : {}
      end

      def contribution_offers_by_need(user)
        profile_ids = @offering_partner_profile_options.map(&:last)
        scope = Decidim::Bih::ContributionOffer.active.where(
          organization: current_organization,
          contribution_need: @contribution_needs
        )
        scope = scope
                .where(contributor: user, partner_profile_id: nil)
                .or(scope.where(partner_profile_id: profile_ids))
                .order(created_at: :desc)
        scope.each_with_object({}) { |offer, offers| offers[offer.contribution_need_id] ||= offer }
      end

      def public_project_links
        Decidim::Bih::ProjectDonationLink
          .active
          .where(organization: current_organization)
          .joins(:partner_project_submission)
          .merge(Decidim::Bih::PartnerProjectSubmission.approved)
          .includes(:project, :partner_project_submission)
          .order(created_at: :desc)
          .select { |link| public_project?(link.project) }
      end

      def project_row(link, submissions, moderated_project_ids, mappings)
        project = link.project
        return unless project

        submission = submissions[project.id]
        return if moderated_project_ids.include?(project.id) && submission.nil?

        mapping = mappings[project.id]
        totals = project_field(mapping, :totals)
        raised = project_field(totals, :total)&.to_d
        {
          link:,
          project:,
          submission:,
          raised:,
          totals_available: !raised.nil?,
          donate_url: project_field(mapping, :donate_url).presence || campaign_donate_url(link.campaign_key)
        }
      end

      def selected_submission_profile
        @partner_profiles.find { |candidate| candidate.id.to_s == submission_params[:partner_profile_id].to_s }
      end

      def build_submission(profile, user)
        Decidim::Bih::PartnerProjectSubmission.new(
          submission_params.except(:partner_profile_id, :lock_version).merge(
            organization: current_organization,
            partner_profile: profile,
            representative: user,
            review_status: "draft"
          )
        )
      end

      def persist_and_submit(submission, user)
        result = nil
        Decidim::Bih::PartnerProjectSubmission.transaction do
          submission.save!
          result = Decidim::Bih::SubmitPartnerProjectSubmission.call(submission, representative: user)
          raise ActiveRecord::Rollback unless result == :ok
        end
        result
      end

      def handle_submission_result(result, success_key)
        if result == :ok
          flash[:notice] = t("decidim.bih.community_projects.flash.#{success_key}")
          redirect_to community_projects_path(anchor: "moji-projekti")
        else
          @submission.errors.add(:base, t("decidim.bih.community_projects.flash.invalid")) if @submission.errors.empty?
          render :new, status: :unprocessable_entity
        end
      end

      def render_invalid_submission(error, user)
        @submission = error.record if error.record.is_a?(Decidim::Bih::PartnerProjectSubmission)
        @submission ||= Decidim::Bih::PartnerProjectSubmission.new
        @partner_profiles ||= eligible_partner_profiles(user)
        flash.now[:alert] = @submission.errors.full_messages.first || t("decidim.bih.community_projects.flash.invalid")
        render :new, status: :unprocessable_entity
      end

      def approved_submissions
        Decidim::Bih::PartnerProjectSubmission
          .approved
          .where(organization: current_organization)
          .joins(:partner_profile)
          .merge(Decidim::Bih::PartnerProfile.publicly_visible)
          .includes(:partner_profile, :project)
      end

      def durable_approved_submissions
        Decidim::Bih::PartnerProjectSubmission
          .approved
          .where(organization: current_organization)
          .includes(:partner_profile, :project)
      end

      def redirect_legacy_project
        link = Decidim::Bih::ProjectDonationLink
               .active
               .where(organization: current_organization)
               .includes(:project)
               .find_by(decidim_budgets_project_id: params[:id])
        return render_not_found unless link && native_public_project?(link.project)

        redirect_to(native_project_path(link.project), status: :moved_permanently)
      end

      def partner_participation_enabled?
        Decidim::Bih::PartnerProfile.publicly_visible.exists?(
          id: @partner_profile.id,
          decidim_organization_id: current_organization.id
        )
      end

      def public_project?(project)
        valid_project_record?(project) &&
          configured_community_budget?(project) &&
          hidden_storage_available?(project)
      rescue StandardError
        false
      end

      def native_public_project?(project)
        valid_project_record?(project) && project.visible? && native_hierarchy_public?(project)
      rescue StandardError
        false
      end

      def valid_project_record?(project)
        project.present? && project.try(:deleted_at).blank?
      end

      def configured_community_budget?(project)
        configured_budget_id = Decidim::Bih::Setting
                               .namespace_for(current_organization, "community_projects")
                               .fetch("budget_id", nil)
                               .to_i

        configured_budget_id.positive? && project.budget.id == configured_budget_id
      end

      def hidden_storage_available?(project)
        component = project.component
        space = component&.participatory_space
        component&.published? && space&.organization == current_organization && !space.published?
      end

      def native_hierarchy_public?(project)
        component = project.component
        space = component&.participatory_space
        component&.published? && space&.published? && participatory_space_visible?(space)
      end

      def participatory_space_visible?(space)
        !space.respond_to?(:visible?) || space.visible?
      end

      def eligible_partner_profiles(user)
        profile_ids = content_partner_profiles(user).map(&:id)
        return [] if profile_ids.empty?

        Decidim::Bih::PartnerProfile
          .publicly_visible
          .where(organization: current_organization, id: profile_ids)
          .to_a
          .sort_by(&:display_name)
      end

      def content_partner_profiles(user)
        return [] unless user

        Decidim::Bih::PartnerMembership
          .for_user(user, organization: current_organization)
          .where(role: Decidim::Bih::PartnerMembership::CONTENT_ROLES)
          .includes(:partner_profile)
          .filter_map(&:partner_profile)
          .uniq
          .sort_by(&:display_name)
      end

      def editable_submissions(user)
        profiles = eligible_partner_profiles(user)
        return Decidim::Bih::PartnerProjectSubmission.none if profiles.empty?

        Decidim::Bih::PartnerProjectSubmission
          .where(organization: current_organization, partner_profile: profiles, review_status: "changes_requested")
      end

      def eligible_offering_partner_profiles(user)
        return [] unless user

        Decidim::Bih::PartnerMembership
          .for_user(user, organization: current_organization)
          .where(role: Decidim::Bih::PartnerMembership::VOLUNTEER_ROLES)
          .includes(:partner_profile)
          .filter_map(&:partner_profile)
          .select(&:volunteer_opportunity_eligible?)
          .uniq
          .sort_by(&:display_name)
      end

      def submission_forbidden
        flash[:alert] = t("decidim.bih.community_projects.flash.forbidden")
        redirect_to community_projects_path
      end

      def submission_params
        params.require(:partner_project_submission).permit(
          :partner_profile_id,
          :title,
          :description,
          :budget_amount,
          :address,
          :starts_on,
          :ends_on,
          :lock_version
        )
      end

      def donations_provider
        Decidim::Bih.donations_provider_for(organization: current_organization)
      end

      def donation_mappings_by_project_id
        @donation_mappings_by_project_id ||= provider_project_mappings.index_by do |mapping|
          project_field(mapping, :decidim_project_id).to_i
        end
      end

      def provider_project_mappings
        provider = donations_provider
        return [] unless provider.respond_to?(:project_mappings)

        Array(provider.project_mappings(organization: current_organization))
      rescue ArgumentError
        Array(provider.project_mappings)
      end

      def campaign_donate_url(campaign_key)
        provider = donations_provider
        return unless provider.respond_to?(:donate_url)

        provider.donate_url(campaign: campaign_key)
      rescue ArgumentError
        nil
      end

      def project_field(object, key)
        return if object.nil?
        return object.public_send(key) if object.respond_to?(key)
        return object[key] || object[key.to_s] if object.respond_to?(:[])

        nil
      end

      def render_not_found
        raise ActionController::RoutingError, "Not Found"
      end

      def native_project_path(project)
        Decidim::EngineRouter.main_proxy(project.component).budget_project_path(
          budget_id: project.budget.id,
          id: project.id
        )
      end

      helper_method def community_project_details_path(project, submission)
        submission ? community_project_path(project.id) : native_project_path(project)
      end
    end
  end
end
