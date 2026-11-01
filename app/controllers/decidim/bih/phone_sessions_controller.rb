# frozen_string_literal: true

module Decidim
  module Bih
    # Allows returning users with a granted SMS authorization to request a
    # passwordless login link by phone number (no enumeration: identical response
    # regardless of whether the phone is found).
    class PhoneSessionsController < Decidim::ApplicationController
      include CompletesPhoneAuthentication

      CHALLENGE_SESSION_KEY = :decidim_bih_phone_login_challenge
      REQUESTED_SESSION_KEY = :decidim_bih_phone_login_requested

      skip_before_action :store_current_location
      before_action :protect_challenge_response

      def new
        redirect_to decidim.new_user_session_path
      end

      def create
        # The same rule the registration form applies (PhoneRegistrationForm
        # #normalized_phone): a local "06X XXX XXX" becomes "+3876XXXXXXX",
        # which is how the verified number was hashed into the authorization.
        # Without this a citizen typing their number the way they say it got a
        # silent "sent" and no message (2026-09-07).
        phone = Decidim::Bih::PhoneRegistrationForm.canonical_phone(params[:phone])
        clear_login_challenge
        challenge = maybe_send_login_challenge(phone)
        store_login_challenge(challenge) if challenge
        session[REQUESTED_SESSION_KEY] = true

        flash[:notice] = t("decidim.bih.phone_sessions.create.sent")
        redirect_to decidim.new_user_session_path
      end

      def verify_code
        stored = session[CHALLENGE_SESSION_KEY]
        token = verify_stored_code(stored)
        return render_invalid_code unless token

        raw_token = stored.fetch("raw_token")
        completed = complete_phone_authentication(
          user: token.user,
          purpose: "login",
          phone: token.phone,
          grant: -> { granted_login_authorization?(token) },
          consume: -> { PhoneChallenge.consume!(raw_token:, organization: current_organization) }
        )
        return clear_login_challenge if completed

        render_invalid_code
      rescue KeyError, Redis::BaseError
        render_invalid_code
      end

      private

      # Looks up a user by their verified phone's SHA-256 unique_id, mints a
      # login token and enqueues the ordered phone-delivery policy. Silent on
      # no-match so callers cannot enumerate registered phones from timing or
      # response differences.
      def maybe_send_login_challenge(phone)
        return if phone.blank?

        # +phone+ is already normalized (params sanitized in #create with the same
        # gsub the helper applies); unique_id_for re-normalizes idempotently, so
        # the result is byte-identical to the previous inline formula.
        unique_id = Decidim::Bih::SmsAuthorization.unique_id_for(phone)
        # The unique_id is organization-INDEPENDENT and its index is non-unique, so
        # an unscoped lookup can return another organization's row (cross-org
        # collision/DoS). Scope to the current organization via the user
        # association, mirroring Viber::AccountLinking#resolve_decidim_user_id.
        authorization = unique_active_granted_sms_authorization(
          Decidim::Authorization
            .where(name: "sms", unique_id:)
            .joins(:user)
            .merge(Decidim::User.where(organization: current_organization))
        )
        return unless authorization

        user = authorization.user

        challenge = PhoneChallenge.issue!(user:, phone:)
        url = Decidim::Bih.magic_link_url(challenge.raw_token, host: current_organization.host)
        # The SMS leg renders under the Latin sibling of the request locale —
        # same rule, same reasons, as every other SMS this platform sends (see
        # Decidim::Bih::Sms.latin_locale_for). The ASCII fallback is what a
        # host with no engine locales would send, so it is diacritic-free too.
        text = I18n.with_locale(Decidim::Bih::Sms.latin_locale_for(I18n.locale)) do
          I18n.t(
            "decidim.bih.sms.login_link_and_code",
            url:,
            code: challenge.otp_code,
            default: format(
              "MI: link za prijavu: %{url} Rezervni kod: %{code}. Vazi 10 min. Ne dijeli ga.",
              url:, code: challenge.otp_code
            )
          )
        end
        enqueue_login_message(phone, text, challenge:, url:)
        challenge
      rescue StandardError => e
        Rails.logger.error(
          "[PhoneSessions] login challenge enqueue failed: " \
          "#{Decidim::Bih::LogRedactor.error_message(e)}"
        )
        nil
      end

      # Enqueues the provider-managed Viber Business Messages -> WhatsApp ->
      # SMS chain outside the request (avoids a timing oracle and keeps the raw
      # token out of logs). A dev-only info line logs only the masked phone.
      def enqueue_login_message(phone, text, challenge:, url:)
        unless Rails.env.production?
          Rails.logger.info(
            "[PhoneSessions] (non-production) login challenge delivery enqueued for " \
            "#{Decidim::Bih::LogRedactor.mask_phone(phone)}"
          )
        end

        Decidim::Bih::Infobip::SendPhoneMessageJob.perform_later(
          to: phone,
          text: text,
          viber_text: I18n.t("decidim.bih.sms.login_link", url:),
          otp_code: challenge.otp_code,
          viber_template: login_viber_template(challenge.raw_token),
          expires_at: challenge.expires_at
        )
      end

      def store_login_challenge(challenge)
        # Rails' session is encrypted by the host. The raw token must not be
        # emitted into the code form, DOM, JSON, flash or a second URL.
        session[CHALLENGE_SESSION_KEY] = {
          "raw_token" => challenge.raw_token,
          "organization_id" => current_organization.id
        }
      end

      def clear_login_challenge
        session.delete(CHALLENGE_SESSION_KEY)
        session.delete(REQUESTED_SESSION_KEY)
      end

      def verify_stored_code(stored)
        return unless stored.is_a?(Hash)
        return unless stored["organization_id"].to_i == current_organization.id

        PhoneChallenge.verify_code(
          raw_token: stored.fetch("raw_token"),
          code: params[:verification_code],
          organization: current_organization
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

      def render_invalid_code
        flash.now[:alert] = t("decidim.bih.phone_sessions.verify_code.invalid")
        @challenge_pending = true
        render :new, status: :unprocessable_entity
      end

      # Through the cache_control API, not a raw header: Decidim's
      # HttpCachingDisabler already populated that API and ActionDispatch
      # merges it over the raw header at commit, dropping `private` on a
      # signed-in response (see PhoneVerificationActions#protect_response).
      def protect_challenge_response
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Pragma", "no-cache")
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
      end

      def login_viber_template(token)
        config = Decidim::Bih::Config.infobip
        return if config[:viber_login_template_id].blank?

        {
          template_id: config[:viber_login_template_id],
          language: config[:viber_template_language],
          parameters: { token: token }
        }
      end
    end
  end
end
