# frozen_string_literal: true

module Decidim
  module Bih
    # "Potvrdi e-mail" from Moj nalog. Phone-first sign-up activates the account
    # with `skip_confirmation!`, so `confirmed_at` no longer means "clicked the
    # e-mail link" and the address a citizen typed is unproven. This controller
    # is the only way to prove it after the fact, and proving it does exactly
    # one thing: it records the address in
    # Decidim::Bih::EmailConfirmation, which is what password recovery
    # (spec 9.2) reads. It NEVER verifies the phone, never grants an
    # authorization and never awards points — the SMS/Viber round trip stays
    # the only door to those.
    #
    # The link is bound to the address it was sent to, by a SALTED DIGEST of
    # that address in the signing purpose. A digest rather than the address
    # itself: `signed_id` only signs its payload, it does not encrypt it, so a
    # purpose carrying the plaintext address would put the citizen's e-mail
    # into a URL (and from there into proxy logs and browser history) for
    # anyone who can base64-decode. Salted with the application secret, the
    # same way Decidim::Bih::Throttling.phone_key is, because a bare digest
    # only hides an address from someone who cannot guess it: with a leaked
    # link anyone could test candidate addresses offline until one matched.
    # Changing the address changes the digest either way, so a token minted for
    # the old address stops verifying — a stale link can never prove an address
    # the citizen no longer has.
    #
    # Following the link requires being signed in as the citizen it was minted
    # for. That is deliberate: the plan's signed-out variant needed to read the
    # user id out of the token before verifying it, which Rails 7.2 purpose-
    # scoped signed ids do not allow. Requiring the session also means a token
    # that leaks (a forwarded mail, a shared log line) is worth nothing on its
    # own.
    class EmailConfirmationsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      PURPOSE_PREFIX = "email_confirmation:"
      TTL = 2.days
      REQUEST_COOLDOWN = 20.minutes
      REQUESTED_AT_KEY = "mi_email_confirmation_requested_at"

      before_action :protect_token_response, only: [:show]
      before_action :require_citizen!

      # POST {mount}/potvrdi-email
      def create
        user = current_organization_user
        return redirect_to(account_overview_path) if user.email.blank?

        # Nothing to prove: the account page only offers the button while the
        # address is unproven, so a POST that arrives anyway (a stale tab, a
        # double submit, a re-post) must not spend a message on a question
        # already answered.
        if Decidim::Bih::EmailConfirmation.confirmed?(user)
          flash[:notice] = t(".already_confirmed")
          return redirect_to(account_overview_path)
        end

        if cooldown_active?(user)
          flash[:alert] = t(".cooldown")
          return redirect_to(account_overview_path)
        end

        token = confirmation_token_for(user)
        # Spend the cooldown BEFORE handing the message off, the same way
        # PhoneVerification::ResendBudget does: a delivery that fails somewhere
        # downstream must not leave the citizen able to re-request in a loop.
        stamp_requested_at!(user)
        Decidim::Bih::EmailConfirmationMailer.confirm(user, token).deliver_later

        flash[:notice] = t(".sent")
        redirect_to account_overview_path
      end

      # GET {mount}/potvrdi-email/:token
      def show
        user = current_organization_user
        address = user.email.to_s.downcase
        verified = Decidim::User.find_signed(params[:token].to_s, purpose: token_purpose(address))

        if verified && verified.id == user.id
          Decidim::Bih::EmailConfirmation.mark_confirmed!(user, address)
          flash[:notice] = t(".confirmed")
        else
          flash[:alert] = t(".invalid")
        end

        redirect_to account_overview_path
      end

      private

      def require_citizen!
        return if current_organization_user

        flash[:alert] = t("decidim.bih.email_confirmations.login_required")
        # Decidim's HasStoredPath has already stored this GET in the session,
        # so Devise returns the citizen to the link after signing in. Passing
        # the URL as `redirect_url` instead would copy the token into the
        # sign-in URL, i.e. into a second path nobody redacts.
        redirect_to decidim.new_user_session_path
      end

      def cooldown_active?(user)
        raw = user.extended_data.to_h[REQUESTED_AT_KEY]
        return false if raw.blank?

        last = Time.zone.parse(raw.to_s)
        last.present? && last > REQUEST_COOLDOWN.ago
      rescue ArgumentError
        # Unparseable residue is not a cooldown; the request proceeds and
        # overwrites it with a well-formed stamp.
        false
      end

      def stamp_requested_at!(user)
        payload = user.extended_data.to_h.merge(REQUESTED_AT_KEY => Time.current.utc.iso8601)
        user.update_column(:extended_data, payload) # rubocop:disable Rails/SkipsModelValidations
      end

      def confirmation_token_for(user)
        user.signed_id(purpose: token_purpose(user.email.to_s.downcase), expires_in: TTL)
      end

      # Same recipe as Decidim::Bih::Throttling.phone_key: normalise, then salt
      # with the application secret so the digest cannot be walked backwards
      # by testing candidate addresses.
      def token_purpose(address)
        normalized = address.to_s.strip.downcase
        "#{PURPOSE_PREFIX}#{Digest::SHA256.hexdigest("#{normalized}-#{Rails.application.secret_key_base}")}"
      end

      # The raw credential is part of the request path. Neither the redirect
      # nor anything a shared cache might keep of it may outlive the request,
      # and the token must not travel on to the next site as a referrer.
      #
      # Cache-Control goes through the cache_control API, not a raw header:
      # Decidim's Headers::HttpCachingDisabler already populated that API
      # (`no-cache` + `no-store`) in an earlier before_action, and at commit
      # time ActionDispatch merges the API over whatever the raw header says —
      # so a plain set_header here would silently lose `private` and ship
      # "no-cache, no-store" instead. Verified against actionpack 7.2.3.2.
      def protect_token_response
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Pragma", "no-cache")
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
        response.set_header("X-Robots-Tag", "noindex, nofollow")
      end
    end
  end
end
