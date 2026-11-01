# frozen_string_literal: true

module Decidim
  module Bih
    # "/registracija" — the one-step account (spec 5.2–5.4). One form opens the
    # account; the pending page that follows carries the citizen from "we sent
    # you a message" to a signed-in session, by the code they type or by the
    # link they tap on a phone that is not this browser.
    #
    # NOBODY IS SIGNED IN HERE until a phone is proven. Every action after
    # #create is therefore gated by a Registration::PendingAccess token instead
    # of by a session, and +verification_user+ — never +current_user+ — answers
    # for the citizen: CompletesPhoneAuthentication decides whether to sign in
    # on Devise's +user_signed_in?+, so a controller that made +current_user+
    # answer for a pending citizen would silently skip the very sign-in it came
    # for.
    #
    # Sign-in happens in exactly two places and both go through
    # CompletesPhoneAuthentication (R-D2): the typed code (#confirm, inherited
    # from PhoneVerificationActions) and the desktop hand-off (#status). The
    # difference between the two pending-access variants is what most of this
    # controller is about. The token minted into the registering browser's own
    # session may be handed that session and may point the verification at a
    # different phone; the one mailed to an address nobody has proven may do
    # NEITHER. All it can do is act on the number already on the row — resend
    # to it, or type the code that came to it — plus start over, which throws
    # the whole never-verified account away rather than redirecting it.
    #
    # The page body, the resend/code/change actions and the poll's shape are
    # shared with delivery A's phone-verification page
    # (Decidim::Bih::PhoneVerificationActions).
    class RegistrationsController < Decidim::ApplicationController
      # Decidim::ApplicationController does NOT carry the form factory — the
      # controllers that look as though it does pick it up from
      # Decidim::UserProfile. Without this, #form is simply not there and
      # /registracija 500s on its first POST.
      include Decidim::FormFactory
      include Decidim::Bih::CurrentOrganizationUser
      include Decidim::Bih::CompletesPhoneAuthentication
      include Decidim::Bih::PhoneVerificationActions

      # Where the registering browser keeps its pending token. NEVER read from
      # a request parameter: that it lives in the session is the entire proof
      # that this is the browser that did the registering (see
      # Registration::PendingAccess's controller contract).
      SESSION_KEY = :mi_pending_registration

      # Everything the pending page can do. #resend, #confirm, #change and
      # #status come from PhoneVerificationActions, so the callback cop cannot
      # see them here.
      PENDING_ACTIONS = [:pending, :resend, :confirm, :change, :status, :start_over].freeze

      helper_method :registration_form_path, :pending_page_path, :pending_action_path, :referral_code_for_form

      before_action :redirect_signed_in_citizen, only: [:new, :create]
      # FIRST among this controller's own callbacks, because the two below it
      # can answer with a 302 and those redirects need the headers too — the
      # one that cleans ?pending_token= out of the URL most of all, since the
      # URL it is getting rid of is the credential that would otherwise travel
      # in a Referer. Not prepend_before_action: Decidim::ApplicationController
      # disables HTTP caching in a before_action of its own, and prepending
      # would put protect_response BEFORE that and let it overwrite the
      # `private` directive (see #protect_response). Parent callbacks run
      # first, so "first here" is exactly the right place.
      #
      # Only the pending page. The sign-up form itself carries nothing private
      # and is a page the platform WANTS found: no-store and a noindex there
      # would keep the front door out of search results for no gain.
      before_action :protect_response, only: PENDING_ACTIONS
      before_action :adopt_email_token, only: [:pending]
      before_action :load_pending_registration, only: PENDING_ACTIONS
      before_action :load_authorization, only: PENDING_ACTIONS

      def new
        # The invite link lands here with ?ref=<nickname>; the code waits in the
        # session until #open_pending_page spends it on the new account.
        Decidim::Bih::Goodwill::Referrals.capture_from_params(params, session)
        @form = form(Decidim::Bih::PhoneRegistrationForm).instance
        @form.newsletter = true
      end

      def create
        # The form carries the referral code as a hidden field too, so a browser
        # that lost its cookie between opening the form and submitting it still
        # attributes the invitation. Same capture, same guards; the session
        # copy wins when it is there.
        Decidim::Bih::Goodwill::Referrals.capture_from_params(params, session) if session[Decidim::Bih::Goodwill::Referrals::SESSION_CODE_KEY].blank?
        # current_locale AFTER the submitted params, exactly as Decidim's own
        # registrations controller does it: the locale is ours to state, not
        # the form's to carry.
        @form = form(Decidim::Bih::PhoneRegistrationForm).from_params(
          params.fetch(:user, {}).merge(current_locale:)
        )

        Decidim::Bih::RegisterWithPhone.call(@form) do
          on(:ok) { |user, token| open_pending_page(user, token) }
          on(:recovery_sent) do
            flash[:notice] = t("decidim.bih.simplified_registration.recovery")
            redirect_to registration_form_path
          end
          on(:delivery_failed) do |user, token|
            # The account is open and the pending page can send the message
            # again, so this is a notice about one failed send — not a failed
            # registration, and never a reason to throw the account away.
            flash[:alert] = t(".delivery_failed")
            open_pending_page(user, token)
          end
          on(:invalid) do
            flash.now[:alert] = t(".invalid")
            render :new, status: :unprocessable_entity
          end
        end
      end

      def pending
        # With no live verify token there is no number left to name, nothing to
        # resend to and nothing a typed code could confirm — the shared body
        # says so instead of masking nothing, and this page offers the one way
        # forward it has: a new number.
        @expired = !live_phone?
        # Session variant only: the field that points the verification at a
        # different phone is the field that decides who owns this account.
        @change_number = @handoff && (@expired || params[:promijeni].present?)
      end

      # The poll, as a POST: this endpoint can sign the waiting browser in, and
      # that must never be a GET (R-D4).
      #
      # It is also the declaration that makes the action routable at all:
      # ActionController::Metal delegates a public #status to the response, so
      # a #status inherited only from PhoneVerificationActions is dropped from
      # #action_methods and the poll 404s. Every controller including that
      # module declares its own for that reason — this one would have had a
      # body here anyway.
      def status
        return super unless phone_proven?

        return hand_off! if hand_off_allowed?

        # An e-mail-variant token may SEE that the phone is confirmed and
        # nothing more: the address it was sent to is unproven, so it can never
        # be the thing that opens a session. The honest answer is where to sign
        # in — which the phone it has just proven can do.
        render json: { state: "verified", next: phone_login_destination }
      end

      # "Wrong number": the same button delivery A's page has, doing the one
      # thing it can do here. A's version destroys the authorization and sends
      # the citizen back to the phone form; this citizen has no session to take
      # a form with, and their e-mail address is now taken by the account they
      # just opened, so /registracija would refuse them. The row therefore
      # stays and only the live link dies — the number is re-entered on the
      # pending page itself and #resend rewrites the row with it.
      #
      # SESSION VARIANT ONLY. Pointing the verification at a different phone is
      # the one thing that decides WHO ends up owning this account, and the
      # e-mail token is a credential that arrived at an address nobody has
      # proven: whoever reads that inbox would otherwise redirect the account
      # to their own number and take the identity. The citizen who really did
      # lose their browser is not stranded — #start_over is their exit.
      def change
        return refuse_without_session_variant unless @handoff

        Decidim::Bih::LoginToken.invalidate_live!(user: verification_user, purpose: "verify")
        flash[:notice] = t(".changed")
        redirect_to sms_form_path
      end

      # A `phone` param means "send it to this number instead" — the same
      # redirection #change starts, and the same session-variant rule.
      # Everything else is the shared resend, which only ever sends to the
      # number already on the row and is therefore open to both variants.
      def resend
        return refuse_without_session_variant if params[:phone].present? && !@handoff
        return resend_to_new_number if params[:phone].present?

        super
      end

      # The way out for the citizen who mistyped the number AND no longer has
      # the browser they registered in: throw the whole thing away and register
      # again with the same e-mail address. Destroying the account is what
      # frees that address and that number, and it is only ever allowed while
      # the account has nothing in it — see #startable_over?.
      def start_over
        # Twice on purpose. This first, unlocked read is the cheap refusal —
        # the account somebody has already used never reaches a lock at all.
        # The one that DECIDES runs inside the transaction, under the row lock.
        return refuse_start_over unless startable_over?
        return refuse_start_over if destroy_pending_registration! == :refused

        session.delete(SESSION_KEY)
        flash[:notice] = t("decidim.bih.registrations.pending.started_over")
        redirect_to registration_form_path
      end

      private

      # ------------------------------------------------------------- the seams

      # The citizen this page is proving a phone for. NOT current_user: nobody
      # is signed in here yet, and CompletesPhoneAuthentication reads Devise to
      # decide whether it still has to sign someone in.
      def verification_user
        @pending_user
      end

      def page_path = pending_page_path

      # SESSION VARIANT ONLY — see #change for why. The shared body reads this
      # to decide whether to render the change-number button at all: for the
      # e-mail variant that button can only ever produce needs_session, and a
      # dead end promoted to the primary action is worse than no button.
      def number_change_allowed? = @handoff

      # Where "enter the number again" goes. Delivery A sends the citizen to
      # Decidim's SMS form; that form needs a session this citizen does not
      # have, so here it is the pending page's own number field.
      def sms_form_path = pending_page_path(promijeni: 1)

      # --------------------------------------------------------- entry gates

      def redirect_signed_in_citizen
        return unless current_organization_user

        redirect_to signed_in_destination
      end

      # Where a citizen who turns out to be signed in already belongs: the same
      # onboarding chain every finished phone verification lands on.
      def signed_in_destination
        phone_authentication_next_step_path(user: current_organization_user, purpose: "verify")
      end

      # ?pending_token= only ever arrives from the resume e-mail. Move it into
      # the session and out of the URL — a URL is what ends up in a Referer, a
      # proxy log and a shared screen — and mint the E-MAIL variant from the
      # resolved citizen rather than storing what arrived, so a session-variant
      # token pasted into the URL cannot be laundered into session rights.
      def adopt_email_token
        token = params[:pending_token].to_s
        return if token.blank?

        access = Decidim::Bih::Registration::PendingAccess.resolve(token, organization: current_organization)
        return refuse_email_token if access.nil?

        # A citizen who opens their own reminder in the browser they registered
        # in keeps the rights they already had: overwriting a live session
        # variant with an e-mail one would take the number change away from the
        # very browser that is allowed to do it.
        session[SESSION_KEY] = Decidim::Bih::Registration::PendingAccess.mint_email(access[:user]) if adoptable_email_access?(access)
        redirect_to pending_page_path
      end

      # The mailed link is dead: expired, tampered with, or another
      # organization's. It used to bounce the citizen silently to the pending
      # page, from there to the form, and the form then refused the address
      # they had registered with — three steps to no explanation. Say it once,
      # on the page that can do something about it.
      #
      # WHICH page that is depends on the browser, not on the dead link. One
      # that is itself mid-registration keeps its own pending page: its session
      # variant is untouched by whatever arrived in the URL, and the flash's
      # "register again" would only dead-end on "this e-mail is taken" for the
      # account it has already opened. A browser with nothing of its own gets
      # the form, which is the one thing it can act on.
      def refuse_email_token
        flash[:alert] = t("decidim.bih.registrations.new.link_expired")
        return redirect_to(pending_page_path) if own_pending_access?

        redirect_to registration_form_path
      end

      # Does THIS browser's own session still open a pending page? Read from
      # the session and nowhere else — that it lives there is the whole proof
      # that this is the browser that did the registering.
      def own_pending_access?
        Decidim::Bih::Registration::PendingAccess.resolve(
          session[SESSION_KEY], organization: current_organization
        ).present?
      end

      def adoptable_email_access?(access)
        access.present? && !session_variant_for?(access[:user])
      end

      def session_variant_for?(user)
        held = Decidim::Bih::Registration::PendingAccess.resolve(
          session[SESSION_KEY], organization: current_organization, allow_verified: true
        )
        held.present? && held[:handoff] && held[:user] == user
      end

      def load_pending_registration
        access = Decidim::Bih::Registration::PendingAccess.resolve(
          session[SESSION_KEY],
          organization: current_organization,
          # Only the poll may see an account that has just been verified: it is
          # the request that has to report the good news to the browser that
          # was watching, instead of going blank at the moment of success.
          allow_verified: action_name == "status"
        )
        return refuse_pending_access if access.nil?

        @pending_user = access[:user]
        @handoff = access[:handoff]
      end

      # Two refusals that look the same and are not: a citizen whose phone was
      # proven somewhere else HAS an account, and sending them to the
      # registration form would only have it refuse the e-mail address they
      # just registered with. The second resolve exists to tell those apart and
      # decides nothing else.
      def refuse_pending_access
        finished = Decidim::Bih::Registration::PendingAccess.resolve(
          session[SESSION_KEY], organization: current_organization, allow_verified: true
        )
        session.delete(SESSION_KEY)

        return redirect_to(signed_in_destination) if current_organization_user

        if finished
          # Named, not silent: this citizen's phone is proven, the account is
          # theirs, and the only thing missing is a session.
          flash[:alert] = t("decidim.bih.registrations.pending.no_longer_pending")
          return redirect_to(phone_login_destination)
        end

        redirect_to registration_form_path
      end

      def load_authorization
        @authorization = sms_authorization_for(verification_user)
      end

      # ------------------------------------------- what the e-mail token cannot

      # Refused, not silently ignored, and it names the way out: the citizen
      # holding only the mailed link is told where the number can be changed
      # and that starting over is the alternative.
      def refuse_without_session_variant
        flash[:alert] = t("decidim.bih.registrations.pending.needs_session")
        redirect_to pending_page_path
      end

      def refuse_start_over
        flash[:alert] = t("decidim.bih.registrations.pending.start_over_refused")
        redirect_to pending_page_path
      end

      # An account that may be thrown away holds NOTHING: no proven phone, no
      # session anyone has ever opened, no points and no authority. The
      # sign-in count is what makes "no content" true rather than merely
      # likely — a password-less account nobody has signed into cannot have
      # authored, voted, followed or reported anything.
      def startable_over?
        Decidim::Bih::Registration::PendingLifecycle.stub?(verification_user)
      end

      # The rows this flow created, and nothing else. The komšiluk assignment
      # and the pending authorization are destroyed explicitly rather than left
      # to cascade, because an orphan `sms` row would go on claiming the number
      # the citizen is about to type again.
      #
      # The lock is what makes the decision safe: between #start_over's cheap
      # first read and this transaction the account can acquire the very thing
      # that makes it un-throwable — a grant from a link tapped on the phone a
      # second ago — so the guard is re-run here, on a locked row, and this
      # answer is the one that counts. A second POST that arrives while the
      # first still holds the lock finds no row at all afterwards; that is
      # "already started over", not a 500.
      #
      # Returns :destroyed, :refused (the locked re-check said no) or :gone.
      def destroy_pending_registration!
        Decidim::Bih::Registration::DestroyStub.call(verification_user)
      end

      # The referral code the form should carry: the one in the URL, else the
      # one this browser already captured. Nickname-shaped only, so nothing
      # else from a URL is ever echoed into the page.
      def referral_code_for_form
        code = params[:ref].presence || session[Decidim::Bih::Goodwill::Referrals::SESSION_CODE_KEY]
        code = code.to_s.strip
        code if Decidim::Bih::InviteLinksController::CODE.match?(code)
      end

      # --------------------------------------------------------------- create

      # Both outcomes that reach here have an account, and this browser's
      # session still carries whatever referral code brought it — which is why
      # the code is spent HERE and not, as for every Devise sign-up, in the
      # Warden hook. Nobody is signed in yet, and the sign-in that eventually
      # happens goes through CompletesPhoneAuthentication, which resets the
      # session first: the hook would find an empty one. Idempotent, and it
      # pays nothing — the referrer is still rewarded by the invitee's grant
      # plus the activity gate.
      def open_pending_page(user, token)
        Decidim::Bih::Goodwill::Referrals.attribute_from_session(session, user)
        session[SESSION_KEY] = token
        redirect_to pending_page_path
      end

      # ------------------------------------------------------- the hand-off

      def phone_proven?
        @authorization&.granted? && !phone_missing_after_grant?
      end

      # The session variant is what may be handed over, and only while a verify
      # credential was live recently enough for this to still be the citizen's
      # own action. Neither is the proof: the phone was proven by the LoginToken
      # the link path claimed, and #hand_off! re-checks the grant that came out
      # of it.
      def hand_off_allowed?
        @handoff && Decidim::Bih::Registration::PendingAccess.handoff_window_open?(verification_user)
      end

      def hand_off!
        destination = capture_completion_redirect do
          complete_phone_authentication(
            user: verification_user,
            purpose: "verify",
            # The link path already claimed the one-time token and performed
            # the grant inside that claim's transaction; this re-checks it,
            # which is what CompletesPhoneAuthentication asks a caller whose
            # proof was consumed elsewhere to do.
            grant: -> { @authorization.reload.granted? }
          )
        end
        # Two very different "no destination" cases, told apart rather than
        # both logged as though something were wrong. :not_completed is the
        # grant no longer standing — a legitimate refusal this poll is supposed
        # to make. :no_redirect is CompletesPhoneAuthentication finishing
        # WITHOUT redirecting, which would mean the poll silently stopped
        # handing browsers forward: a defect, and the only one worth waking
        # somebody for. Either way the citizen gets an answer they can act on.
        Rails.logger.warn("[registracija] hand-off produced no destination for user #{verification_user&.id}") if destination == :no_redirect
        return render(json: { state: "verified", next: phone_login_destination }) if destination.is_a?(Symbol)

        render json: { state: "verified", next: destination }
      end

      # CompletesPhoneAuthentication finishes with a redirect, which is the
      # right answer for a browser navigation and the wrong one for a poll:
      # fetch follows the redirect, gets HTML back, and the page's own script
      # treats a non-JSON answer as terminal — the citizen would be signed in
      # and left staring at the pending page. The sign-in must still go through
      # that one boundary (R-D2), so the redirect it performs is captured here
      # and reported as the poll's `next` instead of being sent. Nothing about
      # the sign-in changes: Warden writes the session at the end of the
      # request whatever body this action renders.
      # Returns the captured destination, or a symbol saying which kind of
      # nothing happened: :not_completed (the concern declined — the grant no
      # longer stands) or :no_redirect (it completed and redirected nowhere,
      # which is a defect). One blank answer for both would have the caller
      # warn about a refusal that is working exactly as designed.
      def capture_completion_redirect
        @capturing_completion_redirect = true
        @captured_completion_redirect = nil
        return :not_completed unless yield

        @captured_completion_redirect.presence || :no_redirect
      ensure
        @capturing_completion_redirect = false
      end

      # Inert outside #capture_completion_redirect, which only the status poll
      # enters. Private on purpose: a public method defined on a controller
      # class is added back to #action_methods even when the framework declares
      # it internal, and "redirect_to" has no business being routable.
      def redirect_to(options = {}, response_options = {})
        return @captured_completion_redirect = options if @capturing_completion_redirect

        super
      end

      # ---------------------------------------------------- the new number

      # A number change spends a paid message like any resend, so it spends the
      # same budget, through the same seam
      # (PhoneVerificationActions#spend_message_budget!). The 60-second
      # cooldown is deliberately NOT applied: it exists to stop a second
      # message to the SAME phone, and a citizen who has just noticed their own
      # typo must not be made to wait a minute to fix it. The total budget
      # still bounds it at five messages per account.
      def resend_to_new_number
        phone = typed_phone(params[:phone])
        return refuse_new_number(:phone_invalid) if phone.blank?
        return refuse_new_number(:phone_taken) if Decidim::Bih::SmsAuthorization.taken?(phone, organization: current_organization)
        return refuse_new_number(:phone_pending) if live_claim_elsewhere?(phone)
        return unless spend_message_budget!

        release_stale_claims!(phone)
        # The number the row held BEFORE the send: after it, @authorization
        # already carries the new one and there is nothing left to compare.
        previous_unique_id = @authorization.unique_id
        # Under the SAME row lock PhoneVerification::Complete takes (spec 5.4).
        # The rewrite moves the number the authorization is keyed on, and a
        # link tapped in that same instant would otherwise grant the row on the
        # NEW, unproven number while CitizenPhone records the old one. The
        # budget reset is inside it too: it decides on the unique_id this block
        # has just written, and reading that outside the lock is reading a
        # number somebody else may already have changed.
        verification_user.with_lock do
          # Decidim's own step, on the same authorization row: it rewrites the
          # unique_id, the code and code_sent_at, and the gateway mints a fresh
          # link to the new number.
          deliver_again(phone)
          reset_challenge_budget!(phone, previous_unique_id)
        end
        redirect_to page_path
      end

      # A DIFFERENT number is a different challenge, so the wrong-code budget
      # starts again — which is what makes confirm.exhausted's "…or change the
      # number" true. Two guards, and both matter. The row must have actually
      # moved to the number that was typed: a send Decidim refused leaves the
      # old number (and its already-spent guesses) in place, and handing back
      # five attempts for a code nobody re-sent would be a free extra set. And
      # it must have MOVED: re-typing the number already on the row is not a
      # new challenge, and paying for it with a fresh set of guesses would
      # make the wrong-code cap a formality — type five, resend to yourself,
      # type five more. Only reachable from the session variant, so this
      # cannot be spent by whoever reads the mailed link.
      def reset_challenge_budget!(phone, previous_unique_id)
        current = @authorization.reload.unique_id
        return unless current == Decidim::Bih::SmsAuthorization.unique_id_for(phone)
        return if current == previous_unique_id

        attempt_limiter.reset!
      end

      # The same three messages the registration form itself would have shown
      # for the same three refusals — one wording, one place, whichever step
      # the citizen is on when they type the number.
      def refuse_new_number(reason)
        flash[:alert] = t("decidim.bih.registrations.errors.#{reason}")
        redirect_to sms_form_path
      end

      # Somebody ELSE is mid-verification on this number right now. The bound
      # is Registration::PhoneClaims', shared with RegisterWithPhone, so the
      # form and this page cannot disagree about which claims are live — and so
      # the phone_pending copy's "try again in 24 hours" stays true instead
      # of describing a row that never expires.
      def live_claim_elsewhere?(phone)
        Decidim::Bih::Registration::PhoneClaims.claimed_elsewhere?(
          phone, organization: current_organization, except_user: verification_user
        )
      end

      # An abandoned claim has to let the number GO, not merely be ignored:
      # Decidim's own AuthorizationHandler#duplicate refuses to verify a number
      # that any other authorization row holds, so leaving one would strand
      # this citizen on a number the page just told them was free. The other
      # citizen's ROW survives the release — see Registration::PhoneClaims.
      def release_stale_claims!(phone)
        ActiveRecord::Base.transaction do
          Decidim::Bih::Registration::PhoneClaims.release_stale!(
            phone, organization: current_organization, except_user: verification_user
          )
        end
      end

      # The same normalisation the registration form applies, taken from the
      # same place: a number accepted there must not be refused here, one step
      # later, with the citizen already waiting for a message.
      def typed_phone(typed)
        shape = Decidim::Bih::PhoneRegistrationForm
        raw = Decidim::Bih::SmsAuthorization.normalize(typed)
        raw = "#{shape::E164_PREFIX}#{raw.delete_prefix("0")}" if raw.match?(shape::LOCAL_NUMBER)

        raw.match?(shape::E164) ? raw : nil
      end

      # ----------------------------------------------------------- the paths

      # Every citizen-facing URL is built from the base this HOST serves the
      # one-step registration at (Decidim::Bih.registration_base_path, e.g.
      # "/registracija"), falling back to the engine-mounted path. A citizen
      # who arrived at the short path must not be walked under the engine mount
      # halfway through the flow. The rule itself lives in
      # Decidim::Bih.registration_path_for, which the resume e-mail reads too.
      def registration_form_path = Decidim::Bih.registration_path_for

      def pending_page_path(**query) = pending_action_path(nil, **query)

      def pending_action_path(suffix = nil, **query)
        path = "#{registration_form_path}/potvrda#{suffix}"
        query = query.compact
        query.empty? ? path : "#{path}?#{query.to_query}"
      end

      # Not named phone_login_path: delivery A's page reaches the engine's own
      # routes through the decidim_bih proxy, and shadowing a route helper with
      # a controller method is how the two quietly disagree.
      def phone_login_destination = decidim.new_user_session_path
    end
  end
end
