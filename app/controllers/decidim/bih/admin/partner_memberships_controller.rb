# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Admin-managed organization membership and control assignments.
      class PartnerMembershipsController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:partner_profiles_manage) }
        before_action :load_profile

        def create
          user = find_user
          role = requested_role
          status = "pending"

          if user.blank? || role.blank? || status.blank?
            flash[:alert] = t(".invalid")
            return redirect_to memberships_partner_profile_path(@profile)
          end

          @profile.with_lock do
            membership = @profile.memberships.where(organization: current_organization, user:).first_or_initialize
            membership.lock! if membership.persisted?
            event_type = membership.new_record? ? "partner_membership_added" : "partner_membership_updated"
            membership.assign_attributes(
              organization: current_organization,
              user:,
              role:,
              status:,
              invited_by: current_user
            )
            apply_status_timestamps(membership)
            membership.save!
            audit_membership!(event_type, membership)
            @invitation = membership if membership.pending?
          end
          notify_invitation(@invitation) if @invitation
          flash[:notice] = t(".saved")
          redirect_to memberships_partner_profile_path(@profile)
        rescue ActiveRecord::RecordInvalid => e
          flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
          redirect_to memberships_partner_profile_path(@profile)
        end

        def update
          membership = find_membership
          return membership_not_found unless membership

          @profile.with_lock do
            membership.lock!
            role = requested_role(default: membership.role)
            status = requested_status(default: membership.status)
            status = "pending" if status == "accepted" && !membership.accepted?
            raise ActiveRecord::RecordInvalid, membership if role.blank? || status.blank?

            membership.assign_attributes(role:, status:)
            apply_status_timestamps(membership)
            membership.save!
            audit_membership!("partner_membership_updated", membership)
          end
          flash[:notice] = t(".saved")
          redirect_to memberships_partner_profile_path(@profile)
        rescue ActiveRecord::RecordInvalid => e
          flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
          redirect_to memberships_partner_profile_path(@profile)
        end

        def destroy
          membership = find_membership
          return membership_not_found unless membership

          @profile.with_lock do
            membership.lock!
            membership.update!(status: "revoked", revoked_at: Time.current)
            audit_membership!("partner_membership_revoked", membership)
          end
          flash[:notice] = t(".revoked")
          redirect_to memberships_partner_profile_path(@profile)
        rescue ActiveRecord::RecordInvalid => e
          flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
          redirect_to memberships_partner_profile_path(@profile)
        end

        private

        def load_profile
          @profile = Decidim::Bih::PartnerProfile
                     .where(organization: current_organization)
                     .find_by(id: params[:partner_profile_id])
          render_not_found unless @profile
        end

        def find_membership
          @profile.memberships.where(organization: current_organization).find_by(id: params[:id])
        end

        def membership_not_found
          flash[:alert] = t(".not_found")
          redirect_to memberships_partner_profile_path(@profile)
        end

        def users_scope
          Decidim::User
            .where(organization: current_organization, deleted_at: nil)
            .not_user_group
        end

        def find_user
          users_scope.find_by(id: membership_params[:decidim_user_id])
        end

        def requested_role(default: nil)
          raw = membership_params[:role].to_s
          return default if raw.blank?

          raw.presence_in(Decidim::Bih::PartnerMembership::ROLES)
        end

        def requested_status(default: nil)
          raw = membership_params[:status].to_s
          return default if raw.blank?

          raw.presence_in(Decidim::Bih::PartnerMembership::STATUSES)
        end

        def membership_params
          params
            .fetch(:partner_membership, ActionController::Parameters.new)
            .permit(:decidim_user_id, :role, :status)
        end

        def apply_status_timestamps(membership)
          case membership.status
          when "accepted"
            membership.accepted_at ||= Time.current
            membership.revoked_at = nil
          when "pending"
            membership.accepted_at = nil
            membership.revoked_at = nil
          when "revoked"
            membership.revoked_at ||= Time.current
          end
        end

        def notify_invitation(membership)
          Decidim::Bih::PartnerMembershipNotifications.publish_invitation(
            membership:,
            organizations_url: decidim_bih.organizations_path
          )
        end

        def audit_membership!(event_type, membership)
          audit_operator_action!(
            event_type,
            permission: "partner_profiles_manage",
            resource: membership,
            metadata: {
              profile_id: @profile.id,
              profile_slug: @profile.slug,
              user_id: membership.decidim_user_id,
              role: membership.role,
              status: membership.status
            }
          )
        end
      end
    end
  end
end
