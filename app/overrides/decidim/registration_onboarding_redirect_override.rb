# frozen_string_literal: true

# Keep the core Decidim registration form, but make the phone-first chain
# (phone → komšiluk → account) the continuation after sign-up and after an
# e-mail confirmation. Decidim::Bih::Onboarding::NextStep owns the order.
#
# Every DESTINATION change here is gated on Decidim::Bih.phone_first_registration.
# A host that has not opted in registers no :sms verification workflow (see
# config/initializers/decidim_sms.rb and decidim-verifications' sms engine), so
# NextStep's phone form would be a 404 there — with the switch off both hooks
# keep pointing at the setup checklist they pointed at before phone-first
# existed. Signing the citizen in on confirmation is the one unconditional
# change, because that is what core already did.
module Decidim
  module Bih
    # Shared by both overrides below: they are prepended to two unrelated
    # Devise controllers, so there is no common superclass to extend.
    module OnboardingRedirectDestination
      private

      def bih_onboarding_destination(resource)
        return mi_account_setup_path unless Decidim::Bih.phone_first_registration

        Decidim::Bih::Onboarding::NextStep.for(resource, organization: current_organization)
      end

      def mi_account_setup_path
        "#{Decidim::Bih.public_path("moj-nalog")}?setup=1"
      end
    end

    module RegistrationOnboardingRedirectOverride
      include OnboardingRedirectDestination

      private

      def after_sign_up_path_for(resource)
        bih_onboarding_destination(resource)
      end

      def after_inactive_sign_up_path_for(resource)
        new_session_path(::Devise::Mapping.find_scope!(resource), redirect_url: mi_account_setup_path)
      end
    end

    module ConfirmationOnboardingRedirectOverride
      include OnboardingRedirectDestination

      private

      # This REPLACES core's after_confirmation_path_for; `super` is never
      # called, so two things core does are not inherited:
      #
      #   1. `sign_in(resource)` — reinstated here, unconditionally and before
      #      anything else, exactly as core does it. It is deliberately not
      #      guarded by `signed_in?`: a browser already signed in as somebody
      #      else must end up signed in as the account whose link was just
      #      clicked, not left on the previous session.
      #   2. `store_onboarding_cookie_data!` and the redirect to
      #      decidim_verifications.onboarding_pending_authorizations_path —
      #      dropped on purpose. NextStep (or, with the switch off, the setup
      #      checklist) owns the continuation on this platform, and core's
      #      pending-authorization detour would compete with it.
      def after_confirmation_path_for(resource_name, resource)
        sign_in(resource_name, resource)

        bih_onboarding_destination(resource)
      end
    end
  end
end

Decidim::Devise::RegistrationsController.prepend(
  Decidim::Bih::RegistrationOnboardingRedirectOverride
)
Decidim::Devise::ConfirmationsController.prepend(
  Decidim::Bih::ConfirmationOnboardingRedirectOverride
)
