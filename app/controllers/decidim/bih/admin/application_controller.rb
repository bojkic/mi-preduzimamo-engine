# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Base controller for decidim-bih operator pages, rendered inside
      # Decidim's admin chrome.
      class ApplicationController < Decidim::Admin::ApplicationController
        layout "decidim/bih/admin"

        # Decidim's admin TOS callback assumes broad Decidim admin/process roles.
        # BIH operators are intentionally narrower, so this engine enforces its
        # own capability gate below while leaving the rest of Decidim admin alone.
        skip_before_action :tos_accepted_by_admin, raise: false
        before_action :ensure_bih_operator_access!

        helper_method :bih_allowed?, :current_bih_permissions

        private

        def ensure_bih_operator_access!
          return if current_user && current_bih_permissions.any?

          raise Decidim::ActionForbidden
        end

        def ensure_global_admin!
          raise Decidim::ActionForbidden unless current_user&.admin? && current_bih_permissions.any?
        end

        def require_bih_permission!(permission, resource: nil)
          return if bih_allowed?(permission, resource:)

          raise Decidim::ActionForbidden
        end

        def bih_allowed?(permission, resource: nil)
          Decidim::Bih::OperatorAuthorization.allowed?(
            current_user,
            permission,
            organization: current_organization,
            resource:
          )
        end

        def current_bih_permissions
          @current_bih_permissions ||= Decidim::Bih::OperatorAuthorization.permissions_for(
            current_user,
            organization: current_organization
          )
        end

        def current_bih_role_for(permission)
          Decidim::Bih::OperatorAuthorization.role_for(
            current_user,
            permission,
            organization: current_organization
          )
        end

        def audit_operator_action!(event_type, permission:, resource: nil, metadata: {})
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: current_organization,
            actor: current_user,
            event_type:,
            permission:,
            role: current_bih_role_for(permission),
            resource:,
            metadata:
          )
        end
      end
    end
  end
end
