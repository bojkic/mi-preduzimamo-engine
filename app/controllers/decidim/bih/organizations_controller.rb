# frozen_string_literal: true

module Decidim
  module Bih
    # Public directory and profile workflow for verified local organizations.
    #
    # GET  /biceriseno/organizacije            -> verified org directory + my orgs
    # GET  /biceriseno/organizacije/nova       -> request org profile
    # POST /biceriseno/organizacije            -> create submitted org profile
    # GET  /biceriseno/organizacija/:id          -> read-only org goodwill
    # POST /biceriseno/organizacija/:id/regrant  -> regrant (group-admin only)
    # POST /biceriseno/organizacija/:id/obavjestenja -> publish a notice
    # POST /biceriseno/organizacija/:id/clanovi -> add a public member
    class OrganizationsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      def index
        @profiles = Decidim::Bih::PartnerProfile
                    .publicly_visible
                    .where(organization: current_organization)
                    .order(:display_name)
        @my_memberships = if current_organization_user
                            Decidim::Bih::PartnerMembership
                              .for_user(current_organization_user, organization: current_organization)
                              .joins(:partner_profile)
                              .includes(:partner_profile)
                              .order("decidim_bih_partner_profiles.display_name")
                          else
                            []
                          end
        @pending_memberships = if current_organization_user
                                 Decidim::Bih::PartnerMembership
                                   .pending
                                   .where(organization: current_organization, user: current_organization_user)
                                   .includes(:partner_profile, :invited_by)
                                   .order(:created_at)
                               else
                                 []
                               end
      end

      def new
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.organizations.flash.login_required")
          destination = new_organization_profile_path
          CitizenReturnPath.store(session, organization: current_organization, path: destination)
          return redirect_to(decidim.new_user_session_path(redirect_url: destination))
        end

        @profile = Decidim::Bih::PartnerProfile.new(
          organization: current_organization,
          kind: "association",
          verification_status: "submitted"
        )
      end

      def create
        user = current_organization_user
        unless user
          flash[:alert] = t("decidim.bih.organizations.flash.login_required")
          return redirect_to(organizations_path)
        end

        @profile = Decidim::Bih::PartnerProfile.new(public_profile_params)
        @profile.organization = current_organization
        @profile.verification_status = "submitted"

        Decidim::Bih::PartnerProfile.transaction do
          @profile.save!
          @profile.memberships.create!(
            organization: current_organization,
            user:,
            role: "owner",
            status: "accepted",
            accepted_at: Time.current,
            invited_by: user
          )
        end
        flash[:notice] = t("decidim.bih.organizations.flash.submitted")
        redirect_to(organizations_path)
      rescue ActiveRecord::RecordInvalid => e
        @profile = e.record if e.record.is_a?(Decidim::Bih::PartnerProfile)
        flash.now[:alert] = e.record.errors.full_messages.first
        render :new, status: :unprocessable_entity
      end

      def edit
        @profile = editable_profile
        return profile_management_forbidden unless @profile
        return profile_not_correctable unless @profile.rejected? || @profile.verification_status == "draft"

        render :new
      end

      def update
        @profile = editable_profile
        return profile_management_forbidden unless @profile
        return profile_not_correctable unless @profile.rejected? || @profile.verification_status == "draft"

        @profile.assign_attributes(public_profile_params)
        @profile.assign_attributes(
          verification_status: "submitted",
          rejected_at: nil,
          rejection_reason: nil,
          verified_by: nil,
          verified_at: nil
        )
        @profile.save!
        flash[:notice] = t("decidim.bih.organizations.flash.resubmitted")
        redirect_to organizations_path
      rescue ActiveRecord::RecordInvalid => e
        @profile = e.record
        flash.now[:alert] = @profile.errors.full_messages.first
        render :new, status: :unprocessable_entity
      end

      def show
        @profile = find_profile
        return render_not_found if @profile.nil?

        @goodwill_enabled = @profile.goodwill_eligible?
        if @goodwill_enabled
          @goodwill_owner = Decidim::Bih::Goodwill::PartnerOwner.owner_for(@profile)
          @balance = Decidim::Bih::Goodwill::Ledger.new.account_for(@goodwill_owner).balance
        end
        @memberships = visible_memberships(@profile)
        @members = @memberships.map(&:user)
        @is_admin = current_organization_user.present? && profile_manager?(current_organization_user, @profile)
        @notices = @profile.notices.published.recent.limit(10)
        @partner_impact = Decidim::Bih::PartnerImpactSummary.call(partner_profile: @profile)
        load_admin_spending_context if @is_admin && @goodwill_enabled
      end

      def regrant
        @profile = find_profile
        return render_not_found if @profile.nil?

        user = current_organization_user
        unless user
          flash[:alert] = t(".forbidden")
          return redirect_to(organization_path(@profile.slug))
        end

        Decidim::Bih::Goodwill::RegrantPoints.call(
          user,
          @profile.id,
          params[:member_id],
          params[:amount],
          category: params[:grant_category],
          recipient_lookup: params[:recipient_lookup],
          request_key: params[:request_key]
        ) do
          on(:ok) { |member, amount| flash[:notice] = t(".regranted", amount:, name: member.name) }
          on(:forbidden) { flash[:alert] = t(".forbidden") }
          on(:insufficient) { flash[:alert] = t(".insufficient") }
          on(:invalid) { flash[:alert] = t(".invalid") }
        end

        redirect_to(organization_path(@profile.slug))
      end

      def create_spending_request
        @profile = find_profile
        return render_not_found if @profile.nil?

        user = current_organization_user
        unless user
          flash[:alert] = t(".forbidden")
          return redirect_to(organization_path(@profile.slug))
        end

        Decidim::Bih::Goodwill::CreateOrganizationSpendingRequest.call(
          user,
          @profile.id,
          spending_request_params
        ) do
          on(:ok) { flash[:notice] = t(".submitted") }
          on(:forbidden) { flash[:alert] = t(".forbidden") }
          on(:insufficient) { flash[:alert] = t(".insufficient") }
          on(:invalid) { |record| flash[:alert] = spending_request_error(record) }
        end

        redirect_to(organization_path(@profile.slug, anchor: "zahtjevi-potrosnje"))
      end

      def create_notice
        @profile = find_profile
        return render_not_found if @profile.nil?

        user = current_organization_user
        unless user && profile_content_manager?(user, @profile)
          flash[:alert] = t(".forbidden")
          return redirect_to(organization_path(@profile.slug))
        end

        notice_type = params[:notice_type].to_s == "official" && @profile.official_publisher? ? "official" : "update"
        @profile.notices.create!(
          organization: current_organization,
          author: user,
          title: params[:title],
          body: params[:body],
          notice_type:,
          published_at: Time.current,
          expires_at: parse_notice_expiry
        )
        flash[:notice] = t(".published")
        redirect_to(organization_path(@profile.slug))
      rescue ActiveRecord::RecordInvalid => e
        flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
        redirect_to(organization_path(@profile.slug))
      end

      def add_member
        @profile = find_profile
        return render_not_found if @profile.nil?

        user = current_organization_user
        unless user && profile_manager?(user, @profile)
          flash[:alert] = t(".forbidden")
          return redirect_to(organization_path(@profile.slug))
        end

        member = find_membership_user(params[:member_lookup])
        unless member
          flash[:alert] = t(".not_found")
          return redirect_to(organization_path(@profile.slug))
        end

        result = @profile.with_lock do
          return profile_management_forbidden unless profile_manager?(user, @profile)

          membership = @profile.memberships.where(organization: current_organization, user: member).first_or_initialize
          membership.lock! if membership.persisted?
          if membership.persisted? && membership.accepted?
            :already
          else
            membership.assign_attributes(
              organization: current_organization,
              role: "member",
              status: "pending",
              accepted_at: nil,
              revoked_at: nil,
              invited_by: user
            )
            membership.save!
            @invited_membership = membership
            :invited
          end
        end
        notify_membership_invitation(@invited_membership) if result == :invited
        flash[:notice] = t(result == :already ? ".already_member" : ".invited", name: member_label(member))
        redirect_to(organization_path(@profile.slug))
      rescue ActiveRecord::RecordInvalid => e
        flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
        redirect_to(organization_path(@profile.slug))
      end

      def update_member
        @profile = find_profile
        return render_not_found if @profile.nil?

        actor = current_organization_user
        unless actor && profile_manager?(actor, @profile)
          flash[:alert] = t(".forbidden")
          return redirect_to(organization_path(@profile.slug))
        end

        @profile.with_lock do
          # The same parent lock is held by admin role changes and revocations.
          # Authorization and the target row must be read again after waiting.
          return profile_management_forbidden unless profile_manager?(actor, @profile)

          membership = @profile.memberships.accepted.find_by(id: params[:membership_id])
          return membership_not_found unless membership

          membership.lock!
          from_role = membership.role
          membership.update!(role: params[:role].to_s)
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: current_organization,
            actor:,
            event_type: "partner_membership_role_updated",
            permission: "partner_manager",
            role: "partner_manager",
            resource: membership,
            metadata: { from_role:, to_role: membership.role }
          )
          @updated_member = membership.user
        end
        flash[:notice] = t(".updated", name: member_label(@updated_member))
        redirect_to organization_path(@profile.slug, anchor: "clanovi-organizacije")
      rescue ActiveRecord::RecordInvalid => e
        flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
        redirect_to organization_path(@profile.slug, anchor: "clanovi-organizacije")
      end

      def accept_membership
        membership = current_user_membership
        return membership_not_found unless membership&.pending?

        membership.accept!
        flash[:notice] = t(".accepted", organization: membership.partner_profile.display_name)
        redirect_to organization_path(membership.partner_profile.slug)
      end

      def decline_membership
        membership = current_user_membership
        return membership_not_found unless membership&.pending?

        membership.decline!
        flash[:notice] = t(".declined", organization: membership.partner_profile.display_name)
        redirect_to organizations_path
      end

      def leave_membership
        membership = current_user_membership
        return membership_not_found unless membership&.accepted?

        profile_name = membership.partner_profile.display_name
        membership.leave!
        flash[:notice] = t(".left", organization: profile_name)
        redirect_to organizations_path
      rescue ActiveRecord::RecordInvalid => e
        flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
        redirect_to organizations_path
      end

      private

      def find_profile
        key = params[:id].to_s
        scope = Decidim::Bih::PartnerProfile
                .publicly_visible
                .where(organization: current_organization)
        profile = scope.find_by(slug: key) || scope.find_by(id: key)
        profile || scope.find_by(legacy_user_group_id: key)
      end

      def current_user_membership
        user = current_organization_user
        return if user.blank?

        Decidim::Bih::PartnerMembership
          .where(organization: current_organization, user:)
          .includes(:partner_profile)
          .find_by(id: params[:membership_id])
      end

      def membership_not_found
        flash[:alert] = t("decidim.bih.organizations.memberships.not_found")
        redirect_to organizations_path
      end

      def notify_membership_invitation(membership)
        Decidim::Bih::PartnerMembershipNotifications.publish_invitation(
          membership:,
          organizations_url: organizations_path
        )
      end

      def visible_memberships(profile)
        profile.memberships
               .publicly_visible
               .includes(:user)
               .sort_by { |membership| [membership.role == "owner" ? 0 : 1, membership.user.name.to_s] }
      end

      def editable_profile
        user = current_organization_user
        return if user.blank?

        profile = Decidim::Bih::PartnerProfile
                  .where(organization: current_organization)
                  .find_by(id: params[:id]) ||
                  Decidim::Bih::PartnerProfile.where(organization: current_organization).find_by(slug: params[:id])
        profile if profile && profile_manager?(user, profile)
      end

      def profile_management_forbidden
        redirect_to organizations_path, alert: t("decidim.bih.organizations.flash.edit_forbidden")
      end

      def profile_not_correctable
        redirect_to organizations_path, alert: t("decidim.bih.organizations.flash.not_correctable")
      end

      def profile_manager?(user, profile)
        profile.memberships.accepted.exists?(
          decidim_user_id: user.id,
          role: Decidim::Bih::PartnerMembership::MANAGER_ROLES
        )
      end

      def profile_content_manager?(user, profile)
        profile.memberships.accepted.exists?(
          decidim_user_id: user.id,
          role: Decidim::Bih::PartnerMembership::CONTENT_ROLES
        )
      end

      def public_profile_params
        params.require(:partner_profile).permit(
          :display_name,
          :legal_name,
          :kind,
          :public_description,
          :website,
          :private_contact_name,
          :private_contact_email,
          :private_contact_phone,
          verification_documents: []
        )
      end

      def find_membership_user(raw_lookup)
        lookup = raw_lookup.to_s.strip
        return if lookup.blank?

        normalized = lookup.delete_prefix("@").downcase
        Decidim::User
          .where(organization: current_organization, deleted_at: nil)
          .not_user_group
          .where("LOWER(email) = :lookup OR LOWER(nickname) = :lookup", lookup: normalized)
          .first
      end

      def member_label(user)
        user.name.presence || user.nickname
      end

      def parse_notice_expiry
        raw = params[:expires_on].to_s
        return nil if raw.blank?

        Date.iso8601(raw).in_time_zone.end_of_day
      rescue ArgumentError
        nil
      end

      def load_admin_spending_context
        @grant_category_options = category_options(
          Decidim::Bih::Goodwill::RegrantPoints::MEMBER_REQUIRED_CATEGORIES,
          "decidim.bih.organizations.grant_categories"
        )
        @thank_you_category_options = category_options(
          Decidim::Bih::Goodwill::RegrantPoints::CATEGORIES - Decidim::Bih::Goodwill::RegrantPoints::MEMBER_REQUIRED_CATEGORIES,
          "decidim.bih.organizations.grant_categories"
        )
        @inter_org_category_options = category_options(
          Decidim::Bih::Goodwill::OrganizationSpendingRequest::INTER_ORG_CATEGORIES,
          "decidim.bih.organizations.spending_categories.inter_org_support"
        )
        @reward_sponsorship_category_options = category_options(
          Decidim::Bih::Goodwill::OrganizationSpendingRequest::REWARD_CATEGORIES,
          "decidim.bih.organizations.spending_categories.reward_sponsorship"
        )
        @eligible_spending_targets = Decidim::Bih::PartnerProfile
                                     .goodwill_eligible
                                     .where(organization: current_organization)
                                     .where.not(id: @profile.id)
                                     .order(:display_name)
        @spending_requests = Decidim::Bih::Goodwill::OrganizationSpendingRequest
                             .where(organization: current_organization, source_partner_profile: @profile)
                             .order(created_at: :desc)
                             .limit(10)
      end

      def category_options(keys, scope)
        keys.map { |key| [t("#{scope}.#{key}"), key] }
      end

      def spending_request_params
        params.permit(
          :request_type,
          :target_partner_profile_id,
          :points,
          :category,
          :reward_title,
          :reward_description,
          :reward_stock,
          :reward_cost
        )
      end

      def spending_request_error(record)
        return t(".invalid") if record.nil? || !record.respond_to?(:errors)

        record.errors.full_messages.first || t(".invalid")
      end

      def render_not_found
        head :not_found
      end
    end
  end
end
