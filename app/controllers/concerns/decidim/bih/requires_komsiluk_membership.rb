# frozen_string_literal: true

module Decidim
  module Bih
    # Controller concern that gates Komšiluk board actions.
    #
    # READ gate (index): must have a CitizenProfile with a komsiluk assigned.
    #   Anonymous or unassigned → redirect to the komšiluk picker.
    #
    # WRITE gate (create/zatvori/prijavi): additionally requires a granted `sms`
    #   authorization (phone verification). Sets @citizen_profile for the action.
    #
    # PRIVACY: this concern does NOT expose komšiluk membership to the caller
    # beyond the user's own @citizen_profile. The audience of any given komšiluk
    # is never enumerated here.
    module RequiresKomsilukMembership
      extend ActiveSupport::Concern
      include Decidim::Bih::CurrentOrganizationUser

      # rubocop:disable Rails/LexicallyScopedActionFilter
      included do
        before_action :require_komsiluk_for_reading!, only: [:index, :show, :publication, :photo, :draft_photo, :edit]
        before_action :require_komsiluk_membership!, only: [:create, :update, :zatvori, :prijavi, :help, :resolve]
      end
      # rubocop:enable Rails/LexicallyScopedActionFilter

      private

      # Called for read-only actions: requires a logged-in user with a komšiluk
      # assignment. Anonymous → redirect to login; unassigned → picker prompt.
      def require_komsiluk_for_reading!
        unless current_organization_user
          return head(:not_found) if %w(photo draft_photo).include?(action_name)

          flash[:alert] = t("decidim.bih.komsiluk_board.gate.login_required")
          remember_board_return!
          return redirect_to decidim.new_user_session_path(redirect_url: board_return_path)
        end

        @citizen_profile = citizen_profile_for_current_user
        return if @citizen_profile&.assigned?
        return head(:not_found) if %w(photo draft_photo).include?(action_name)

        flash[:alert] = t("decidim.bih.komsiluk_board.gate.komsiluk_required")
        remember_board_return!
        redirect_to decidim_bih.edit_komsiluk_path(return_to: board_return_path)
      end

      # Called for write actions: requires login + phone verification + assignment.
      def require_komsiluk_membership!
        unless current_organization_user
          flash[:alert] = t("decidim.bih.komsiluk_board.gate.login_required")
          remember_board_return!
          return redirect_to decidim.new_user_session_path(redirect_url: board_return_path)
        end

        unless sms_authorization_granted?
          flash[:alert] = t("decidim.bih.komsiluk_board.gate.sms_required")
          # The user is already logged in here (anonymous case handled above),
          # so send them to the SMS verification flow — not the passwordless
          # login form, which would be a dead-end for a signed-in citizen.
          remember_board_return!
          return redirect_to decidim_verifications.authorizations_path(redirect_url: board_return_path)
        end

        @citizen_profile = citizen_profile_for_current_user
        return if @citizen_profile&.assigned?

        flash[:alert] = t("decidim.bih.komsiluk_board.gate.komsiluk_required")
        remember_board_return!
        redirect_to decidim_bih.edit_komsiluk_path(return_to: board_return_path)
      end

      def board_return_path
        return request.fullpath if request.get?

        decidim_bih.komsiluk_board_index_path(compose: 1)
      end

      def remember_board_return!
        Komsiluk::ReturnPath.store(session, organization: current_organization, path: board_return_path)
        store_location_for(:user, board_return_path) if respond_to?(:store_location_for)
      end

      def citizen_profile_for_current_user
        user = current_organization_user
        return nil unless user

        Decidim::Bih::CitizenProfile.find_by(
          decidim_organization_id: current_organization.id,
          decidim_user_id: user.id
        )
      end

      # True when the current user holds a granted (non-pending) sms authorization.
      def sms_authorization_granted?
        user = current_organization_user
        return false unless user

        Decidim::Authorization
          .find_by(user:, name: "sms")
          &.granted?
      end
    end
  end
end
