# frozen_string_literal: true

require "active_support/concern"

module Decidim
  module Bih
    # Shared final boundary for magic links, typed login codes and the
    # phone-first registration flow. Callers provide the grant and one-time
    # credential claim operations; neither a delivered message nor a copied
    # code reaches sign-in without both operations succeeding.
    module CompletesPhoneAuthentication
      extend ActiveSupport::Concern

      # +grant+ must perform (or re-check) the authorization grant. +consume+
      # atomically claims the presented proof after the grant. Registration's
      # existing Decidim code flow may omit +consume+ because its command owns
      # that one-time proof; it still enters here only after a successful grant.
      # A grant service that invalidates sibling tokens must claim its presented
      # token inside the same grant transaction and omit +consume+ here.
      #
      # A destination is only ever honoured when it is a host-relative path:
      # one leading slash, and a second character that is neither a slash nor
      # a backslash. That rejects "//evil.example" and "/\\evil.example"
      # (browsers normalise the backslash form to the protocol-relative one)
      # as well as any absolute URL or scheme. Anything rejected is dropped in
      # favour of the normal next-step destination — never redirected to.
      HOST_RELATIVE_PATH = %r{\A/[^/\\]}

      # +destination+ overrides the onboarding chain for a caller that already
      # holds a saved answer — the phone-verification page carries Decidim's
      # +redirect_url+, the mid-journey location an action authorizer bounced
      # the citizen away from. Required komšiluk selection comes first for the
      # simplified flow; its saved destination follows that step. The override
      # still goes through #phone_authentication_destination, so the PWA
      # +app=1+ marker is applied uniformly wherever a verify finishes.
      # +notice+ likewise lets a caller keep its own flash copy; the magic-link
      # wording ("… and you are signed in") is wrong on a path where the
      # citizen was signed in all along.
      def complete_phone_authentication(user:, purpose:, grant:, consume: nil, phone: nil, destination: nil, notice: nil) # rubocop:disable Metrics/ParameterLists
        return false unless phone_authentication_allowed?(user)
        return false unless grant.call
        return false if consume && !consume.call

        synchronize_proven_phone(user, phone) unless phone.to_s.empty?

        # The override reaches here from a controller, but it originates in the
        # request (the verification page forwards Decidim's +redirect_url+), so
        # it is re-checked at this boundary rather than trusted because a
        # controller passed it on.
        destination = saved_phone_authentication_destination(destination, purpose:)
        next_step = phone_authentication_next_step_path(user:, purpose:)
        unless user_signed_in?
          reset_session
          sign_in(:user, user)
        end

        destination = onboarding_phone_authentication_destination(user:, purpose:, destination:, next_step:)

        flash[:notice] = notice || t("decidim.bih.magic_links.success.#{purpose}")
        redirect_to phone_authentication_destination(destination, purpose:)
        true
      end

      private

      def saved_phone_authentication_destination(destination, purpose:)
        board_destination = Decidim::Bih::Komsiluk::ReturnPath.consume(session, organization: current_organization)
        citizen_destination = Decidim::Bih::CitizenReturnPath.consume(session, organization: current_organization)
        citizen_destination = nil unless purpose.to_s == "login" || Decidim::Bih.simplified_registration
        host_relative_destination(destination) || board_destination || citizen_destination
      end

      def onboarding_phone_authentication_destination(user:, purpose:, destination:, next_step:)
        needs_komsiluk = Decidim::Bih.simplified_registration && %w(login verify).include?(purpose.to_s) &&
                         next_step.start_with?(Decidim::Bih.public_path("komsiluk"))
        return destination || next_step unless needs_komsiluk

        return_path = if Decidim::Bih::Onboarding::ReturnPath.valid?(destination)
                        destination
                      else
                        Decidim::Bih.public_path("moj-nalog")
                      end
        Decidim::Bih::Onboarding::ReturnPath.store(session, user:, organization: current_organization, path: return_path)
        next_step
      end

      def synchronize_proven_phone(user, phone)
        Decidim::Bih::VerifiedPhone.synchronize!(user:, organization: current_organization, phone:)
      rescue StandardError => e
        Rails.logger.error("[phone_authentication] contact synchronization failed user=#{user.id} error=#{e.class}")
      end

      def host_relative_destination(destination)
        path = destination.to_s
        path.match?(HOST_RELATIVE_PATH) ? path : nil
      end

      def phone_authentication_allowed?(user)
        active_phone_authentication_user?(user) && (!user_signed_in? || current_user == user)
      end

      def active_phone_authentication_user?(user)
        user&.active_for_authentication? && !user.blocked? && !user.deleted?
      end

      # Authorization unique_id is not protected by a database uniqueness
      # constraint. Bound the lookup and fail closed unless exactly one active,
      # unexpired grant matches the caller's organization/user/phone scope.
      def unique_active_granted_sms_authorization(scope)
        matches = scope.where.not(granted_at: nil).includes(:user).limit(2).select do |authorization|
          active_phone_authentication_user?(authorization.user) && !authorization.expired?
        end
        matches.one? ? matches.first : nil
      end

      # Delivery A/D supplies Onboarding::NextStep. Keeping this method small
      # and overridable lets its pending-registration controller preserve only
      # the bounded session handoff it owns before calling this concern.
      def phone_authentication_next_step_path(user:, purpose:)
        if %w(login verify).include?(purpose.to_s) && phone_first_onboarding_chain?
          Decidim::Bih::Onboarding::NextStep.for(user, organization: current_organization)
        else
          anchor = purpose.to_s == "login" ? nil : "zavrsi-nalog"
          decidim_bih.account_overview_path(anchor:)
        end
      end

      # The onboarding chain starts at the :sms verification form, and a host
      # that has not switched phone-first on registers no :sms workflow at all
      # — NextStep would send that host's citizens to a 404. Same gate as
      # app/overrides/decidim/registration_onboarding_redirect_override.rb.
      def phone_first_onboarding_chain?
        defined?(Decidim::Bih::Onboarding::NextStep) && Decidim::Bih.phone_first_registration
      end

      def phone_authentication_destination(destination, purpose:)
        return destination unless purpose.to_s == "verify"

        path, fragment = destination.to_s.split("#", 2)
        unless path.match?(/(?:\?|&)app=/)
          separator = path.include?("?") ? "&" : "?"
          path = "#{path}#{separator}app=1"
        end
        fragment ? "#{path}##{fragment}" : path
      end
    end
  end
end
