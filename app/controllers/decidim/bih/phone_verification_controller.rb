# frozen_string_literal: true

module Decidim
  module Bih
    # "Link je poslan": the citizen has a pending sms authorization and a link
    # (Viber → SMS) on the way. This page never shows the code; it offers
    # resend, forced SMS, number change, a status poll that moves an already
    # signed-in desktop session forward once the link is tapped on the phone,
    # and a visible code field for feature phones.
    #
    # The actions themselves live in Decidim::Bih::PhoneVerificationActions,
    # shared with delivery D's registration pending page. What is A's alone —
    # and therefore still here — is who the citizen is (already signed in),
    # how the page is reached (login required, a pending authorization), where
    # it lives, and where "enter the number again" goes.
    class PhoneVerificationController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser
      include Decidim::Bih::CompletesPhoneAuthentication
      include Decidim::Bih::PhoneVerificationActions

      before_action :require_login!
      before_action :load_authorization
      before_action :ensure_pending!, except: [:status]
      before_action :protect_response

      helper_method :continue_url

      def show; end

      # The whole body is PhoneVerificationActions'; declaring it HERE is what
      # makes the action routable at all — see that module's #status for why a
      # #status that comes only from a module is not. Not useless: without this
      # line the poll 404s.
      def status = super # rubocop:disable Lint/UselessMethodDefinition

      private

      def require_login!
        return if current_organization_user

        redirect_to decidim.new_user_session_path(redirect_url: request.fullpath)
      end

      def load_authorization
        @authorization = sms_authorization_for(current_user)
      end

      # A granted authorization normally means "nothing to do here" and sends
      # the citizen on to NextStep. One case is different: the grant survived
      # but the phone row that should have come with it did not
      # (Decidim::Bih::PhoneVerification::Complete's phone write is
      # best-effort and can fail independently of the grant — see its
      # comment). Bouncing that citizen onward would leave them unaware their
      # future phone-delivered messages (the launch invitation among them)
      # have nowhere to go, so this page renders instead, in a re-verify mode:
      # the citizen types the number they already proved and #confirm matches
      # it against the existing grant (never destroying it); "change the
      # number" (reusing #change, no duplicated transaction) is offered only
      # as the secondary "I no longer have that number" escape hatch.
      def ensure_pending!
        if @authorization&.granted?
          return enter_reverify_mode! if phone_missing_after_grant?

          return redirect_to(destination)
        end
        return if @authorization.present?

        redirect_to sms_form_path
      end

      # Decidim hands us a +redirect_url+ when verification was demanded
      # mid-journey (an action authorizer bounced the citizen here); honour it
      # when it is safe, and let the shared #destination fall back to the
      # onboarding chain otherwise. Decidim::SafeRedirect#redirect_url already
      # rejects anything that is not a path on this organization's host, which
      # is what makes "//evil.example" fall through to NextStep.
      def continue_url
        return @continue_url if defined?(@continue_url)

        @continue_url = begin
          redirect_url.presence
        rescue URI::InvalidURIError
          nil
        end
      end

      def page_path
        decidim_bih.phone_verification_path(redirect_url: continue_url)
      end

      # With phone-first off the host registers no :sms workflow, so the phone
      # form is a 404 there; the setup checklist is the honest destination.
      # Same gate as registration_onboarding_redirect_override.rb.
      def sms_form_path
        return decidim_bih.account_overview_path(anchor: "zavrsi-nalog") unless Decidim::Bih.phone_first_registration

        Decidim::Bih::Onboarding::NextStep::SMS_NEW_PATH
      end
    end
  end
end
