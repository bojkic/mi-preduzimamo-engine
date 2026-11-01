# frozen_string_literal: true

module Decidim
  module Bih
    # Lands and consumes magic-link tokens. GET only *peeks* (Viber/SMS apps
    # prefetch URLs for link previews and must not burn a single-use token);
    # the actual consume happens on the user's explicit POST.
    #
    # SOUNDNESS: the one-time link is delivered to the phone over SMS (and
    # optionally Viber) by InfobipGateway — it is NEVER displayed on the web
    # page. Activating it (browser tap) therefore proves the browser/device is
    # on the same phone that received the SMS/Viber message, which proves phone
    # possession to the same standard as the typed OTP code.
    class MagicLinksController < Decidim::ApplicationController
      include GrantsAuthorization
      include CompletesPhoneAuthentication

      PURPOSES = %w(verify postal login invitation).freeze

      skip_before_action :store_current_location
      before_action :protect_token_response

      def show
        # Prevent the token URL from leaking into Referer headers when the user
        # clicks a link on the confirmation page (e.g. a help/support link).
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
        @token = LoginToken.peek(raw: params[:token], organization: current_organization)
        return render :invalid, status: :unprocessable_entity unless @token

        @purpose = presentation_purpose(@token)
        # An already-confirmed invitation needs no tap: show the result straight away.
        show_invitation_result(@token) if @purpose == "invitation"
      end

      def consume
        token = LoginToken.peek(raw: params[:token], organization: current_organization)
        return render :invalid, status: :unprocessable_entity unless token

        # The invitation link confirms attendance and NOTHING else — it is
        # branched off before any path that could open a session.
        return confirm_invitation(token) if token.purpose == "invitation"

        user = token.user
        # One definition of "a user this flow may sign in", shared with the
        # phone-login and verification paths (CompletesPhoneAuthentication).
        return render :invalid, status: :unprocessable_entity unless active_phone_authentication_user?(user)

        completed = if token.purpose == "postal"
                      complete_postal_link(token)
                    else
                      complete_phone_link(token)
                    end
        return if completed

        render :invalid, status: :unprocessable_entity
      end

      private

      def protect_token_response
        # The raw credential is part of the request path. Do not let browsers,
        # reverse proxies, or shared caches retain either the landing page or
        # the consume response, including invalid-token responses.
        #
        # Through the cache_control API, not a raw header: Decidim's
        # HttpCachingDisabler already populated that API and ActionDispatch
        # merges it over the raw header at commit, dropping `private` on a
        # signed-in response (see PhoneVerificationActions#protect_response).
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Pragma", "no-cache")
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
        response.set_header("X-Robots-Tag", "noindex, nofollow")
      end

      def invitation_for(token)
        return if token.user.blocked? || token.user.deleted?

        Decidim::Bih::Goodwill::LaunchInvitation.for_user(current_organization, token.user)
      end

      def show_invitation_result(token)
        @invitation = invitation_for(token)
        return render :invalid, status: :unprocessable_entity if @invitation.blank?
        return if @invitation.attendance_confirmed_at.blank?

        @outcome = :already_confirmed
        render :invitation_result
      end

      # The token is deliberately NOT consumed: confirming is idempotent, and a
      # citizen who taps the link again should see "already confirmed", not
      # "link invalid". The token still dies with its 72h TTL.
      def confirm_invitation(token)
        @invitation = invitation_for(token)
        return render :invalid, status: :unprocessable_entity if @invitation.blank?

        @outcome = Decidim::Bih::Goodwill::LaunchInvitation.confirm_attendance!(@invitation, actor: token.user, via: "link")
        render :invitation_result
      end

      def presentation_purpose(token)
        token.purpose.to_s.presence_in(PURPOSES) || "verify"
      end

      def complete_phone_link(token)
        return complete_verify_link(token) if token.purpose == "verify"

        challenge = PhoneChallenge.new
        complete_phone_authentication(
          user: token.user,
          purpose: "login",
          phone: token.phone,
          grant: -> { granted_login_authorization?(token) },
          consume: -> { challenge.consume!(raw_token: params[:token], organization: current_organization) }
        )
      end

      # PhoneVerification::Complete voids every live verify LoginToken after a
      # successful grant. Claim this exact proof first in the same transaction;
      # a false grant rolls the claim back, and sign-in happens only after the
      # transaction commits. Concurrent link/code submissions can grant at most
      # idempotently, while only the winner opens a browser session.
      def complete_verify_link(token)
        return false unless phone_authentication_allowed?(token.user)

        granted = false
        LoginToken.transaction(requires_new: true) do
          # Match LoginToken.issue!'s user -> token lock order so a concurrent
          # resend cannot deadlock against this consume path.
          token.user.lock!
          raise ActiveRecord::Rollback unless LoginToken.claim!(token)

          # The one canonical grant (PhoneVerification::Complete). The session
          # is deliberately NOT handed over: the service never reads it (see
          # Complete#confirm!), and passing the real one would invite the
          # assumption that it does. Complete voids the remaining live verify
          # tokens itself, so this path adds no second invalidate_live!.
          result = Decidim::Bih::PhoneVerification::Complete.call(user: token.user, phone: token.phone, session: {})
          unless result.granted?
            # User id and error symbol only — never the phone, the token or a code.
            Rails.logger.info("[decidim-bih] verify link refused for user #{token.user&.id}: #{result.error}")
            raise ActiveRecord::Rollback
          end

          granted = true
        end
        return false unless granted

        complete_phone_authentication(user: token.user, purpose: "verify", grant: -> { true })
      end

      def complete_postal_link(token)
        complete_phone_authentication(
          user: token.user,
          purpose: "postal",
          grant: -> { grant_named_authorization(token.user, "postal_letter", session) },
          consume: lambda do
            LoginToken.consume!(raw: params[:token], organization: current_organization, purpose: "postal")
          end
        )
      end

      def granted_login_authorization?(token)
        phone = token.phone.to_s
        return false if phone.blank?

        unique_active_granted_sms_authorization(
          Decidim::Authorization.where(
            user: token.user,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone)
          )
        ).present?
      end
    end
  end
end
