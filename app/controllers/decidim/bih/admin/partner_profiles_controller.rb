# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Admin review and maintenance for first-class organization profiles.
      class PartnerProfilesController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:partner_profiles_manage) }
        before_action -> { require_bih_permission!(:partner_profiles_verify) }, only: [:verify, :reject, :suspend, :restore]
        before_action :load_profile, only: [:show, :edit, :memberships, :update]

        def index
          @status = params[:status].presence_in(Decidim::Bih::PartnerProfile::VERIFICATION_STATUSES)
          @kind = params[:kind].presence_in(Decidim::Bih::PartnerProfile::KINDS)
          @query = params[:q].to_s.strip
          @profiles = Decidim::Bih::PartnerProfile
                      .where(organization: current_organization)
                      .includes(:verified_by, memberships: :user)
          @profiles = @profiles.where(verification_status: @status) if @status
          @profiles = @profiles.where(kind: @kind) if @kind
          if @query.present?
            query = "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%"
            @profiles = @profiles.where("display_name ILIKE :q OR legal_name ILIKE :q OR slug ILIKE :q", q: query)
          end
          @profiles = @profiles.order(Arel.sql("CASE verification_status WHEN 'submitted' THEN 0 WHEN 'draft' THEN 1 WHEN 'verified' THEN 2 ELSE 3 END"), :display_name)
        end

        def new
          @profile = Decidim::Bih::PartnerProfile.new(
            organization: current_organization,
            verification_status: "submitted",
            kind: "association"
          )
        end

        def create
          @profile = Decidim::Bih::PartnerProfile.new(profile_params)
          @profile.organization = current_organization
          @profile.verification_status ||= "submitted"
          if @profile.save
            audit_profile!("partner_profile_created")
            flash[:notice] = t(".created")
            redirect_to partner_profile_path(@profile)
          else
            flash.now[:alert] = @profile.errors.full_messages.first
            render :new
          end
        end

        def show
          @memberships = memberships_scope
        end

        def edit; end

        def memberships
          load_membership_controls
        end

        def update
          if @profile.update(profile_params)
            audit_profile!("partner_profile_updated")
            flash[:notice] = t(".updated")
            redirect_to partner_profile_path(@profile)
          else
            flash.now[:alert] = @profile.errors.full_messages.first
            render :edit
          end
        end

        def verify
          transition_profile!("partner_profile_verified") { |profile| profile.verify!(by: current_user) }
        end

        def reject
          reason = params[:rejection_reason].to_s.strip
          if reason.blank?
            profile = find_profile
            return render_not_found unless profile

            flash[:alert] = t(".reason_required")
            return redirect_to partner_profile_path(profile)
          end

          transition_profile!("partner_profile_rejected", metadata: { reason_present: true }) do |profile|
            profile.reject!(reason:, by: current_user)
          end
        end

        def suspend
          transition_profile!("partner_profile_suspended", &:suspend!)
        end

        def restore
          transition_profile!("partner_profile_restored") { |profile| profile.restore!(by: current_user) }
        end

        private

        def transition_profile!(event_type, metadata: {})
          @profile = find_profile
          return render_not_found unless @profile
          return redirect_invalid_decision unless decision_controls_valid?

          yield @profile
          audit_profile!(event_type, metadata: metadata.merge(decision_metadata))
          flash[:notice] = t(".updated")
          redirect_to partner_profile_path(@profile)
        rescue ActiveRecord::RecordInvalid => e
          flash[:alert] = e.record.errors.full_messages.to_sentence
          redirect_to partner_profile_path(@profile)
        end

        def decision_controls_valid?
          private_action_reason.valid? && ActiveModel::Type::Boolean.new.cast(params[:evidence_reviewed])
        end

        def redirect_invalid_decision
          flash[:alert] = if private_action_reason.valid?
                            t("decidim.bih.admin.partner_profiles.show.evidence_required")
                          else
                            t(
                              "decidim.bih.admin.private_action_reason.invalid",
                              count: Decidim::Bih::Admin::PrivateActionReason::MAX_LENGTH
                            )
                          end
          redirect_to partner_profile_path(@profile)
        end

        def private_action_reason
          @private_action_reason ||= Decidim::Bih::Admin::PrivateActionReason.new(params[:private_reason])
        end

        def decision_metadata
          private_action_reason.metadata.merge(evidence_reviewed: true)
        end

        def load_profile
          @profile = find_profile
          render_not_found unless @profile
        end

        def find_profile
          Decidim::Bih::PartnerProfile
            .where(organization: current_organization)
            .find_by(id: params[:id])
        end

        def profile_params
          permitted = params.require(:partner_profile).permit(
            :display_name,
            :legal_name,
            :slug,
            :kind,
            :public_description,
            :website,
            :private_contact_name,
            :private_contact_email,
            :private_contact_phone,
            verification_documents: []
          )
          permitted.delete(:slug) if @profile&.verified?
          permitted
        end

        def load_membership_controls
          @member_query = params[:member_q].to_s.strip
          @membership_users = users_scope.none
          if @member_query.length >= 2
            query = "%#{ActiveRecord::Base.sanitize_sql_like(@member_query)}%"
            @membership_users = users_scope.where("name ILIKE :q OR nickname ILIKE :q OR email ILIKE :q", q: query)
          end
          @membership_users = @membership_users.order(:name, :nickname).limit(50)
          @memberships = memberships_scope
        end

        def memberships_scope
          @profile
            .memberships
            .includes(:user, :invited_by)
            .order(Arel.sql("CASE status WHEN 'accepted' THEN 0 WHEN 'pending' THEN 1 ELSE 2 END"), :role, :id)
        end

        def users_scope
          Decidim::User
            .where(organization: current_organization, deleted_at: nil)
            .not_user_group
        end

        def audit_profile!(event_type, metadata: {})
          audit_operator_action!(
            event_type,
            permission: "partner_profiles_manage",
            resource: @profile,
            metadata: metadata.merge(
              kind: @profile.kind,
              status: @profile.verification_status
            )
          )
        end
      end
    end
  end
end
