# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Admin-only operator role management.
      class OperatorRolesController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:operator_roles_manage) }

        DEFAULT_EXPIRY_DAYS = 90

        def index
          load_index
        end

        def create
          user = find_user
          roles = selected_roles
          expires_at = parse_expiry
          approval_rationale = sanitized_rationale

          unless valid_grant_request?(user, roles, expires_at, approval_rationale)
            flash[:alert] = t(".invalid")
            return redirect_to operator_roles_path
          end

          Decidim::Bih::OperatorRole.transaction do
            roles.each do |role|
              grant_operator_role!(user:, role:, expires_at:, approval_rationale:)
            end
          end

          flash[:notice] = t(".saved")
          redirect_to operator_roles_path
        rescue ActiveRecord::RecordInvalid => e
          flash[:alert] = e.record.errors.full_messages.first || t(".invalid")
          redirect_to operator_roles_path
        end

        def revoke
          operator_role = Decidim::Bih::OperatorRole
                          .where(organization: current_organization)
                          .find_by(id: params[:id])
          unless operator_role
            flash[:alert] = t(".not_found")
            return redirect_to operator_roles_path
          end

          operator_role.update!(revoked_at: Time.current)
          audit_operator_action!(
            "operator_role_revoked",
            permission: "operator_roles_manage",
            resource: operator_role,
            metadata: { role: operator_role.role, user_id: operator_role.decidim_user_id }
          )
          flash[:notice] = t(".revoked")
          redirect_to operator_roles_path
        end

        private

        def selected_roles
          Array(params[:roles]).map(&:to_s) & Decidim::Bih::OperatorRole::GRANTABLE_ROLES
        end

        def valid_grant_request?(user, roles, expires_at, approval_rationale)
          user.present? &&
            roles.any? &&
            expires_at.present? &&
            approval_rationale.present? &&
            Decidim::Bih::OperatorRole.grantable_role_set?(
              roles,
              existing_roles: active_role_names_for(user)
            )
        end

        def active_role_names_for(user)
          return [] unless user

          Decidim::Bih::OperatorRole.active_for(user, current_organization).pluck(:role)
        end

        def grant_operator_role!(user:, role:, expires_at:, approval_rationale:)
          operator_role = operator_role_for(user:, role:)
          operator_role.assign_attributes(
            organization: current_organization,
            user:,
            role:,
            created_by: current_user,
            expires_at:,
            revoked_at: nil
          )
          operator_role.assign_attributes(area_scope: params[:area_scope], komsiluk_ids: params[:komsiluk_ids]) if role == "komsiluk_moderator" && params[:area_scope].present?
          operator_role.save!
          audit_operator_role_grant!(operator_role, user:, role:, expires_at:, approval_rationale:)
        end

        def operator_role_for(user:, role:)
          Decidim::Bih::OperatorRole
            .active
            .where(organization: current_organization, user:, role:)
            .order(expires_at: :desc, id: :desc)
            .first_or_initialize
        end

        def audit_operator_role_grant!(operator_role, user:, role:, expires_at:, approval_rationale:)
          audit_operator_action!(
            operator_role.previous_changes.has_key?("id") ? "operator_role_granted" : "operator_role_renewed",
            permission: "operator_roles_manage",
            resource: operator_role,
            metadata: { role:, user_id: user.id, expires_on: expires_at.to_date.iso8601, approval_rationale:,
                        area_scope: operator_role.area_scope, area_count: operator_role.komsiluk_ids.size }
          )
        end

        def load_index
          @komsiluk_areas = Decidim::Bih::LocalArea.komsiluci.where(organization: current_organization).order(Arel.sql("name->>'sr'"), :id).to_a
          @komsiluk_names = @komsiluk_areas.index_by(&:id)
          @query = params[:q].to_s.strip
          @users = users_scope
          @users = @users.where("name ILIKE :q OR nickname ILIKE :q OR email ILIKE :q", q: "%#{ActiveRecord::Base.sanitize_sql_like(@query)}%") if @query.present?
          @users = @users.order(:name, :nickname).limit(50)
          @active_roles = Decidim::Bih::OperatorRole
                          .active
                          .where(organization: current_organization)
                          .includes(:user, :created_by)
                          .order(:role, :expires_at)
          @recent_roles = Decidim::Bih::OperatorRole
                          .where(organization: current_organization)
                          .where("revoked_at IS NOT NULL OR expires_at <= ?", Time.current)
                          .includes(:user, :created_by)
                          .order(Arel.sql("COALESCE(revoked_at, expires_at) DESC"))
                          .limit(20)
          @default_expires_on = DEFAULT_EXPIRY_DAYS.days.from_now.to_date
        end

        def users_scope
          Decidim::User
            .where(organization: current_organization, deleted_at: nil)
            .not_user_group
        end

        def find_user
          users_scope.find_by(id: params[:decidim_user_id])
        end

        def parse_expiry
          raw = params[:expires_on].to_s
          return DEFAULT_EXPIRY_DAYS.days.from_now.end_of_day if raw.blank?

          Date.iso8601(raw).in_time_zone.end_of_day
        rescue ArgumentError
          nil
        end

        def sanitized_rationale
          value = params[:approval_rationale].to_s.strip
          return "" if value.blank?

          if defined?(Decidim::Bih::SafeErrorMetadata)
            Decidim::Bih::SafeErrorMetadata.sanitize_text(value, max: 160)
          else
            value.split.join(" ")[0, 160]
          end
        end
      end
    end
  end
end
