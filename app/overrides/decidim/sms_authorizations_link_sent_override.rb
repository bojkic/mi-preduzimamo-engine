# frozen_string_literal: true

# Decidim's SMS workflow shows a "type the code" page after the phone form.
# Phone-first verification completes by tapping the link, so that page (and
# its code POST) redirect to the engine's "link sent" page, which owns resend,
# forced SMS, number change and the hidden code path. destroy (number change
# from Decidim's own UI) must also void any live link.
#
# Every change here is gated on Decidim::Bih.phone_first_registration, the same
# way registration_onboarding_redirect_override.rb gates its destinations: a
# host that has not opted into phone-first has no "link sent" page in its
# journey and must keep Decidim's own code page exactly as it was.
#
# Decidim hands the workflow a redirect_url when verification was demanded
# mid-journey; it is forwarded so the citizen lands back where they were
# instead of in the onboarding chain — but only after Decidim::SafeRedirect
# has vetted it. The raw parameter is attacker-controlled, and forwarding it
# verbatim would let a crafted /sms/authorizations/edit link plant an
# off-site destination in the engine page's own forms and poll.
module Decidim
  module Bih
    module SmsAuthorizationsLinkSentOverride
      def edit
        return super unless Decidim::Bih.phone_first_registration

        redirect_to link_sent_path
      end

      def update
        return super unless Decidim::Bih.phone_first_registration

        redirect_to link_sent_path
      end

      def destroy
        Decidim::Bih::LoginToken.invalidate_live!(user: current_user, purpose: "verify") if Decidim::Bih.phone_first_registration

        super
      end

      private

      def link_sent_path
        decidim_bih.phone_verification_path(redirect_url: safe_redirect_url)
      end

      # Decidim::SafeRedirect#redirect_url returns nil for anything that is
      # not a path on this organization's host, and raises on a malformed
      # one — which must not 500 a page whose whole job is to move the
      # citizen forward.
      def safe_redirect_url
        redirect_url.presence
      rescue URI::InvalidURIError
        nil
      end
    end
  end
end

Decidim::Verifications::Sms::AuthorizationsController.prepend(Decidim::Bih::SmsAuthorizationsLinkSentOverride)
