# frozen_string_literal: true

require "active_support/concern"

module Decidim
  module Bih
    # The shared body of a "we sent you a message, now prove the phone" page:
    # resend, forced SMS, change the number, the typed code, the re-verify
    # rescue path, and the status poll that hands a waiting browser forward
    # the moment the phone is proven.
    #
    # Two pages are built on this. Delivery A's PhoneVerificationController
    # verifies a citizen who is ALREADY signed in; delivery D's registration
    # pending page verifies one who is not signed in yet. Everything the two
    # do not share is a seam the including controller supplies:
    #
    # * +verification_user+ — the citizen being verified. Defaults to
    #   +current_user+. A controller whose citizen is NOT signed in overrides
    #   this one and never +current_user+: CompletesPhoneAuthentication decides
    #   whether to sign in on Devise's +user_signed_in?+, so a controller that
    #   made +current_user+ answer for a pending citizen would silently skip
    #   the very sign-in it came for.
    # * <tt>@authorization</tt> — that citizen's sms Authorization row, loaded
    #   by the including controller's own before_action, because each page
    #   gates access to it differently (A requires a login, D a pending-access
    #   token).
    # * +page_path+ — where this page lives; every refusal redirects there.
    # * +sms_form_path+ — where "enter the number again" sends the citizen.
    # * +continue_url+ — a caller-supplied destination that wins over the
    #   onboarding chain (A forwards Decidim's +redirect_url+); nil by default.
    # * the copy — every message is a relative <tt>t(".key")</tt>, so it
    #   resolves under the including controller's own i18n scope.
    #
    # The including controller must also include CompletesPhoneAuthentication
    # (the single finish for a proven phone) and register the callbacks it
    # wants; this module deliberately installs none, because which actions
    # need +protect_response+ and which need an authorization loaded differs
    # between the two pages.
    #
    # AttemptLimiter bounds user-supplied code attempts before Complete replays
    # the proven challenge. Decidim 0.32 additionally enforces its persistent
    # authorization lock/expiry when that challenge is granted.
    module PhoneVerificationActions
      extend ActiveSupport::Concern

      CODE_TTL = Decidim::Bih::LoginToken::VERIFY_TTL
      RESEND_COOLDOWN = 60.seconds

      included do
        # The limiters' Redis handle, injectable so environments without Redis
        # (the rails harness) can supply a double. nil means "build the real
        # one", which is what production does. Both counters on this page — the
        # wrong-code AttemptLimiter and the paid-message ResendBudget — share
        # this one handle; they are told apart by their key namespaces, not by
        # their connections.
        class << self
          attr_accessor :attempt_limiter_redis
        end

        helper_method :masked_phone, :live_phone?, :phone_on_record, :whatsapp_code_copy?, :number_change_allowed?
      end

      # --------------------------------------------------------------- actions

      # REQUIRED OF EVERY INCLUDING CONTROLLER: declare `def status = super`.
      #
      # ActionController::Metal delegates a public #status to the response, so
      # AbstractController::Base#action_methods counts "status" among the
      # framework's own methods and drops it — unless the CLASS itself defines
      # it (action_methods adds public_instance_methods(false) back for exactly
      # that reason). A #status inherited only from this module is therefore
      # NOT a routable action: the poll 404s at runtime while every unit test
      # still passes. Both including controllers declare it, which is also why
      # this module does not define it onto them from `included`: a class that
      # writes its own #status (delivery D's does, to answer the hand-off)
      # would silently redefine the one the include had just written, and Ruby
      # warns about that under -w. #resend, #confirm and #change collide with
      # nothing and need no such declaration.
      def status
        state = if @authorization&.granted?
                  # A grant with no saved phone row is the re-verify case (see
                  # #enter_reverify_mode!): reporting "verified" here would have
                  # the page's own status poll redirect the citizen away before
                  # they ever get to act on it. "expired" is the closest
                  # existing state — no live code to check either — and never
                  # triggers a redirect.
                  phone_missing_after_grant? ? "expired" : "verified"
                elsif @authorization.nil? || code_expired?
                  "expired"
                else
                  "pending"
                end
        render json: { state:, next: state == "verified" ? destination : nil }
      end

      # A reverify challenge has no live link to resend — the grant already
      # stands and there is nothing pending to re-send a code for. Refusing
      # outright (rather than falling into the "reenter" branch below, which
      # would send a granted citizen to the phone FORM and implicitly suggest
      # starting over) keeps this a dead end that only ever bounces back to
      # the reverify page itself, never touching the grant.
      def resend
        return redirect_to(page_path) if @reverify

        if resend_too_soon?
          flash[:alert] = t(".too_soon")
          return redirect_to(page_path)
        end

        # The number on record, live link or not: the citizen who comes back
        # from the reminder e-mail days later can still ask for a fresh link.
        phone = phone_on_record
        if phone.blank?
          flash[:alert] = t(".reenter")
          return redirect_to(sms_form_path)
        end

        return unless spend_message_budget!

        # SMS only. A resend means the first chain has already tried Viber and
        # WhatsApp for this number; a second full chain bills those legs again,
        # and — because the first chain's SMS leg is still live for minutes —
        # lands the citizen with two messages carrying two different codes, the
        # older of which no longer works (review 2026-09-07, lane 1 H3).
        deliver_again(phone, channels: ["sms"])
        redirect_to page_path
      end

      def confirm
        return confirm_reverify if @reverify

        limiter = attempt_limiter
        if code_expired?
          flash[:alert] = t(".expired")
          return redirect_to(page_path)
        end

        if limiter.exhausted?
          flash[:alert] = limiter.store_error? ? t(".unavailable") : t(".exhausted")
          return redirect_to(page_path)
        end

        return refuse_code(limiter) unless code_matches?(params[:verification_code])

        grant!(limiter)
      end

      # The ONLY reverify path that destroys the grant — offered there as the
      # secondary "I no longer have that number" escape hatch
      # (show.reverify_change), never the default. Abandoning verification leaves
      # AccountSummary#phone_step back at :todo (no more :reverify — the
      # authorization is gone), and +sms_form_path+ is the including
      # controller's answer to "where does the number get typed again".
      def change
        verification_user.with_lock do
          Decidim::Bih::LoginToken.invalidate_live!(user: verification_user, purpose: "verify")
          Decidim::Bih::LoginToken.invalidate_live!(user: verification_user, purpose: "login")
          @authorization.reload.destroy!
          Decidim::Bih::VerifiedPhone.revoke_destinations!(user: verification_user, organization: current_organization)
        end
        flash[:notice] = t(".changed")
        redirect_to sms_form_path
      end

      private

      # --------------------------------------------------------------- seams

      # The citizen whose phone this page is proving. See the module comment
      # for why a page with an unauthenticated citizen overrides this and not
      # +current_user+.
      def verification_user
        current_user
      end

      # A caller-supplied destination that outranks the onboarding chain. A's
      # page carries Decidim's +redirect_url+ (the mid-journey location an
      # action authorizer bounced the citizen away from); a page with no such
      # notion leaves this nil.
      def continue_url
        nil
      end

      # Where this page lives: every refusal in this module redirects here.
      # REQUIRED — the two pages sit at different paths and neither may build
      # the other's, so there is no sensible default to inherit. Both including
      # controllers define it; this raises rather than letting a third one
      # 500 somewhere further down with nothing pointing back here.
      def page_path = raise(NotImplementedError, "#{self.class} must define #page_path (PhoneVerificationActions seam)")

      # Where "enter the number again" sends the citizen. REQUIRED for the same
      # reason: A hands them Decidim's SMS form, D its own number field on the
      # pending page, and a wrong guess here is a dead end mid-verification.
      def sms_form_path = raise(NotImplementedError, "#{self.class} must define #sms_form_path (PhoneVerificationActions seam)")

      # The i18n scope this controller's copy lives under — the same one a
      # relative <tt>t(".key")</tt> resolves against. Used only where the key
      # cannot be relative because +action_name+ is wrong for it: the reverify
      # copy belongs to the PAGE, so it lives under <tt><scope>.show.*</tt>
      # with the rest of that UI, and is reached from #confirm — where a
      # relative key would resolve under <tt><scope>.confirm.*</tt> instead.
      # An including controller therefore owns <tt><scope>.show.reverify_*</tt>
      # (see #reverify_unavailable_key / #reverify_saved_key) alongside the
      # per-action keys.
      def verification_i18n_scope
        controller_path.tr("/", ".")
      end

      # ---------------------------------------------------------- loading

      def sms_authorization_for(user)
        Decidim::Authorization.find_by(user:, name: "sms")
      end

      # Cache-Control goes through the cache_control API, never a raw header:
      # Decidim's Headers::HttpCachingDisabler populates that API (`no-cache` +
      # `no-store`) in an earlier before_action, and at commit time
      # ActionDispatch merges the API OVER whatever the raw header says. A
      # plain set_header here therefore shipped "no-cache, no-store" on every
      # SIGNED-IN response and silently dropped `private` — the directive that
      # keeps the masked number out of a shared proxy's cache. Anonymous
      # responses kept it, which is why it went unnoticed. Verified against
      # actionpack 7.2.3.2; same fix as EmailConfirmationsController.
      def protect_response
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
        response.set_header("X-Robots-Tag", "noindex, nofollow")
      end

      # ------------------------------------------------------------ reverify

      # Side-effect-free on purpose: #status (a JSON endpoint that never
      # renders the reverify page) needs the same check without touching
      # @reverify.
      def phone_missing_after_grant?
        !Decidim::Bih::VerifiedPhone.consistent?(user: verification_user, organization: current_organization)
      end

      # A granted authorization whose phone row never made it (Complete's
      # phone write is best-effort and can fail independently of the grant —
      # see its comment) puts the page into re-verify mode: the citizen types
      # the number they already proved and #confirm matches it against the
      # existing grant, never destroying it.
      #
      # The limiter is fail-closed, so a Redis outage reads as "exhausted"
      # too. Hiding the phone form for OUR outage would leave the citizen
      # holding nothing but the destructive escape hatch, so the two are told
      # apart here: a real budget exhaustion takes the form away, an
      # unreachable counter only says so and lets them try (see the view).
      def enter_reverify_mode!
        @reverify = true
        limiter = attempt_limiter
        exhausted = limiter.exhausted?
        @reverify_store_error = limiter.store_error?
        @reverify_exhausted = exhausted && !@reverify_store_error
      end

      # ------------------------------------------------------- destinations

      # Where the citizen goes once the phone is proven. A safe caller-supplied
      # +continue_url+ wins; otherwise the onboarding chain answers.
      # Decidim::SafeRedirect#redirect_url (A's source for it) already rejects
      # anything that is not a path on this organization's host, and
      # CompletesPhoneAuthentication re-checks it at the boundary anyway.
      def destination
        continue_url || next_step
      end

      # CompletesPhoneAuthentication owns "where a proven phone lands",
      # including the fact that with phone-first off this host registers no
      # :sms workflow and the onboarding chain's first step is a 404 there.
      # Going through it is what keeps this page's own redirect and the
      # desktop poll's `next` the same answer. The PWA app=1 marker is
      # deliberately NOT added here: it belongs to the completion redirect the
      # concern performs, not to a JSON field a poll follows.
      def next_step
        phone_authentication_next_step_path(user: verification_user, purpose: "verify")
      end

      # ------------------------------------------------------------ cooldown

      # The cooldown lives on the authorization, not in the session: a citizen
      # with two tabs, a cleared cookie or a second device must not be able to
      # pump out messages, and PerformAuthorizationStep rewrites code_sent_at
      # on every successful send, so the row already knows.
      def resend_too_soon?
        sent_at = code_sent_at
        sent_at.present? && sent_at > RESEND_COOLDOWN.ago
      end

      # Re-runs Decidim's own "send the code" step, which goes through the
      # engine's gateway and therefore mints a fresh link too. `channel=sms`
      # restricts delivery for the citizen who never saw the Viber message.
      #
      # The citizen is a from_params ATTRIBUTE, not context. MobilePhoneForm
      # declares `attribute :user`, and with_context only fills the form's
      # context — so `with_context(user:)` left `form.user` nil, the gateway
      # got no user, and it refused to mint a magic link and send at all
      # (PR #14). The organization is genuinely context and stays there.
      def deliver_again(phone, channels: nil)
        channels = ["sms"] if params[:channel].to_s == "sms"
        form = Decidim::Verifications::Sms::MobilePhoneForm.from_params(
          mobile_phone_number: phone, delivery_channels: channels, user: verification_user
        ).with_context(current_organization:)

        Decidim::Verifications::PerformAuthorizationStep.call(@authorization, form) do
          on(:ok) { flash[:notice] = t(".sent") }
          on(:invalid) { flash[:alert] = t(".failed") }
        end
      end

      # ---------------------------------------------------------- typed code

      def code_matches?(submitted)
        code = submitted.to_s.strip
        return false unless code.match?(/\A\d{6}\z/)

        ActiveSupport::SecurityUtils.secure_compare(code, stored_code.to_s)
      end

      # Finishing goes through CompletesPhoneAuthentication, the one place a
      # proven phone turns into a destination, so this page lands exactly where
      # a tapped magic link lands (including the PWA app=1 marker). Where the
      # citizen is already signed in the concern only redirects; where they are
      # not, it is the concern — never this module — that signs them in. A safe
      # +continue_url+ still wins over the onboarding chain.
      def grant!(limiter)
        # session: {} — see MagicLinksController#complete_verify_link for why
        # the real session is never handed to Complete.
        result = Decidim::Bih::PhoneVerification::Complete.call(user: verification_user, phone: live_phone, session: {})
        limiter.reset! if result.granted?

        completed = complete_phone_authentication(
          user: verification_user,
          purpose: "verify",
          grant: -> { result.granted? },
          destination: continue_url,
          notice: t(".verified")
        )
        return if completed

        flash[:alert] = t(".failed")
        redirect_to page_path
      end

      def refuse_code(limiter)
        attempts = limiter.record_failure!
        flash[:alert] = if limiter.store_error?
                          t(".unavailable")
                        elsif attempts >= Decidim::Bih::PhoneVerification::AttemptLimiter::MAX_ATTEMPTS
                          t(".exhausted")
                        else
                          t(".wrong_code")
                        end
        redirect_to page_path
      end

      # ------------------------------------------------------ typed number

      # The reverify path posts to the SAME route as the typed-code path
      # (POST …/kod), but with a `phone` param instead of `verification_code`
      # — no new route, and the same AttemptLimiter budget/throttle already
      # protecting the code path covers this too. Crucially this NEVER
      # destroys @authorization: it only ever calls PhoneVerification::Complete
      # on an ALREADY-granted row, which (per its own contract) records the
      # phone/BusinessContact rows without sending anything or re-confirming.
      def confirm_reverify
        limiter = attempt_limiter
        if limiter.exhausted?
          # Reverify has its own "we cannot count right now" copy: the code
          # page's confirm.unavailable tells the citizen to tap the link from
          # the message, and on this page there is no live link to tap.
          flash[:alert] = limiter.store_error? ? t(reverify_unavailable_key) : t(".exhausted")
          return redirect_to(page_path)
        end

        candidate = matching_reverify_candidate(params[:phone])
        return refuse_reverify_candidate(limiter) if candidate.blank?

        result = Decidim::Bih::PhoneVerification::Complete.call(user: verification_user, phone: candidate, session: {})
        # NOT result.granted?: the grant already stood before this request, so
        # it is true whatever happened to the phone row — including the silent
        # record_phone! failure this whole page exists to recover from.
        # Success here is the row being there, and nothing else; anything less
        # keeps the citizen on the page with copy that says so.
        unless result.phone_recorded?
          flash[:alert] = t(".reverify_not_saved")
          return redirect_to(page_path)
        end

        limiter.reset!

        completed = complete_phone_authentication(
          user: verification_user,
          purpose: "verify",
          grant: -> { result.phone_recorded? },
          destination: continue_url,
          # Fully-qualified: action_name is still "confirm" here, so a
          # relative t(".reverify_saved") would resolve under confirm.* —
          # this copy lives under show.* alongside the rest of the reverify UI.
          notice: t(reverify_saved_key)
        )
        return if completed

        flash[:alert] = t(".failed")
        redirect_to page_path
      end

      # show.* like the rest of the reverify UI, and action_name is "confirm"
      # on this path, so the relative form would resolve under confirm.*.
      def reverify_unavailable_key = "#{verification_i18n_scope}.show.reverify_unavailable"

      def reverify_saved_key = "#{verification_i18n_scope}.show.reverify_saved"

      def refuse_reverify_candidate(limiter)
        attempts = limiter.record_failure!
        flash[:alert] = if limiter.store_error?
                          t(reverify_unavailable_key)
                        elsif attempts >= Decidim::Bih::PhoneVerification::AttemptLimiter::MAX_ATTEMPTS
                          t(".exhausted")
                        else
                          t(".reverify_mismatch")
                        end
        redirect_to page_path
      end

      # At most 3 candidates built from the typed value: as typed (stripped to
      # "+"/digits, the same normalization SmsAuthorization.unique_id_for
      # applies internally) and — when it looks like a BiH number in one of
      # the two common shapes — the OTHER shape (E.164 "+387…" <-> national
      # "0…"), so a citizen who verified with one format and later types the
      # other still matches. No live phone/CitizenPhone lookup is involved:
      # matching is purely against @authorization.unique_id (see
      # #matching_reverify_candidate), so this never reads or writes the
      # citizen's stored number.
      def reverify_phone_candidates(typed)
        normalized = Decidim::Bih::SmsAuthorization.normalize(typed)
        return [] if normalized.blank?

        candidates = [normalized]
        if normalized.start_with?("+387")
          candidates << "0#{normalized.delete_prefix("+387")}"
        elsif normalized.start_with?("0")
          candidates << "+387#{normalized.delete_prefix("0")}"
        end

        candidates.uniq.first(3)
      end

      # The first candidate whose unique_id secure-compares equal to the
      # EXISTING grant's, or nil. Never mutates anything — the caller decides
      # what a match (or its absence) means.
      def matching_reverify_candidate(typed)
        reverify_phone_candidates(typed).find do |candidate|
          ActiveSupport::SecurityUtils.secure_compare(
            Decidim::Bih::SmsAuthorization.unique_id_for(candidate),
            @authorization.unique_id
          )
        end
      end

      # ------------------------------------------------- challenge and phone

      def stored_code
        @authorization&.verification_metadata.to_h["verification_code"]
      end

      def code_sent_at
        raw = @authorization&.verification_metadata.to_h["code_sent_at"]
        raw.present? ? Time.zone.parse(raw.to_s) : nil
      end

      def code_expired?
        code_sent_at.nil? || code_sent_at < CODE_TTL.ago
      end

      # The phone in clear exists only on the live verify token (issued at
      # send time); the authorization itself holds a hash. No token → the
      # citizen re-enters the number.
      def live_phone
        Decidim::Bih::LoginToken.where(user: verification_user, purpose: "verify", consumed_at: nil)
                                .where(expires_at: Time.current..).order(created_at: :desc).first&.phone
      end

      def live_phone?
        live_phone.present?
      end

      # The number the citizen last asked us to message, whether or not that
      # link is still live: the newest verify token keeps it in clear (the
      # authorization row only has a hash). A resend goes here once the link
      # has expired; nil means the citizen has to type the number again.
      def phone_on_record
        Decidim::Bih::LoginToken.where(user: verification_user, purpose: "verify")
                                .order(created_at: :desc, id: :desc).first&.phone
      end

      def masked_phone
        Decidim::Bih::PhoneDisplay.mask(phone_on_record)
      end

      # Whether THIS page may offer "wrong number? change it". A seam, not a
      # constant: the shared body renders that button, and a page where the
      # button can only ever produce a refusal must be able to take it away
      # rather than promote a dead end to the primary action once the link has
      # expired. Delivery A's citizen is signed in and has Decidim's own SMS
      # form behind the button, so the default is "allowed"; delivery D's
      # e-mail variant is the one that says no.
      def number_change_allowed?
        true
      end

      # Whether the code-entry copy may name WhatsApp — only where WhatsApp can
      # actually deliver a code (R-D9). A helper rather than a Config call in
      # the view: the partial is shared by both pages, and asking the page it
      # is rendered by is what keeps the two answering the same way (and makes
      # the branch stubbable from a page test).
      def whatsapp_code_copy?
        Decidim::Bih::Config.whatsapp_phone_auth_configured?
      end

      # ---------------------------------------------------- the paid message

      # Spend one paid message from the per-session budget, or refuse. Spends
      # BEFORE the gateway is touched and judges on what the INCR came back
      # with — never on a separate read first (two tabs that both read "four
      # spent" before either writes both believe there is budget left, and
      # what they win is a paid message each; the atomic increment is the only
      # number that cannot be stale). Same shape as #refuse_code. A spend we
      # could not record refuses too: this counter is what stands between a
      # rotated session and a paid message every minute to somebody else's
      # phone, so the direction to fail in is "no message".
      #
      # Both pages that can pay for a message go through here — the shared
      # #resend and the pending page's "send it to this number instead" — so
      # neither can be used to walk around the other's budget. The copy is
      # relative: every caller is reached from #resend, so the keys resolve
      # under the including controller's own <scope>.resend.*.
      #
      # Returns true when the message may be sent; otherwise sets the flash,
      # redirects to page_path and returns false — callers `return unless`.
      def spend_message_budget!
        budget = resend_budget
        spent = budget.spend!
        return true unless budget.store_error? || spent > Decidim::Bih::PhoneVerification::ResendBudget::MAX_RESENDS

        flash[:alert] = budget.store_error? ? t(".unavailable") : t(".exhausted")
        redirect_to page_path
        false
      end

      # ------------------------------------------------------------ counters

      # The budget is the lifetime of the authorization row, NOT of one code.
      # Keying it on code_sent_at would hand a free set of guesses to anyone
      # who presses "send again", which is the whole attack. Changing the
      # number destroys the row and legitimately starts over.
      def attempt_limiter
        Decidim::Bih::PhoneVerification::AttemptLimiter.new(
          organization_id: current_organization.id,
          authorization_id: @authorization.id,
          challenge_version: @authorization.created_at.to_i,
          redis: self.class.attempt_limiter_redis
        )
      end

      # Same key material and the same "the budget is the lifetime of the
      # authorization row" rule as #attempt_limiter, counting a different
      # thing: messages sent, not codes guessed. Change the number and the row
      # is destroyed, which is the one legitimate way to start over.
      def resend_budget
        Decidim::Bih::PhoneVerification::ResendBudget.new(
          organization_id: current_organization.id,
          authorization_id: @authorization.id,
          challenge_version: @authorization.created_at.to_i,
          redis: self.class.attempt_limiter_redis
        )
      end
    end
  end
end
