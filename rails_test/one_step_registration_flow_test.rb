# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Spec 5.2–5.4: one form opens the account, and the pending page carries
      # the citizen from "we sent you a message" to a signed-in session — by
      # the code they type, or by the link they tap somewhere else entirely.
      #
      # The citizen is NOT signed in anywhere in this flow until a phone is
      # proven, so every action on the pending page is gated by a pending-access
      # token rather than by a session. Two variants of that token exist and the
      # difference between them is the point of most of these tests: the one
      # minted into the registering browser's own session may be handed a
      # session, the one mailed to an unproven address may not.
      class OneStepRegistrationFlowTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveSupport::Testing::TimeHelpers
        include ActiveJob::TestHelper

        PHONE = "+38765123456"
        OTHER_PHONE = "+38765111222"

        # Scoped on purpose (see rails_test/awards_after_verification_test.rb):
        # every ledger award also fires Decidim's :events chain, and performing
        # the mail job would have premailer-rails fetch the layout's CSS over
        # real HTTP from this run's fake host. The points ride this one job.
        AWARD_JOB = Decidim::Bih::Goodwill::GoodwillAwardJob

        # Mirrors the double in rails_test/phone_verification_page_test.rb. The
        # harness host has no Redis and both counters are fail-closed, which
        # would close the code path for every test here.
        class FakeRedis
          def initialize
            @store = {}
            @ttl = {}
          end

          def incr(key) = @store[key] = @store.fetch(key, 0) + 1

          def expire(key, seconds) = @ttl[key] = seconds

          def get(key) = @store[key]&.to_s

          def del(key) = @store.delete(key)

          def eval(_script, keys:, argv:)
            key = keys.first
            value = incr(key)
            expire(key, argv.first) if value == 1
            value
          end
        end

        # Stands in for Decidim.sms_gateway_service so a test can see the
        # context the form handed the gateway — that is where the forced-SMS
        # channel restriction and the user-bound link have to arrive.
        class RecordingGateway
          class << self
            attr_accessor :contexts
          end
          self.contexts = []

          def initialize(_phone, _code, context = {})
            self.class.contexts << (context || {})
          end

          def deliver_code = true
        end

        # The provider that says no. Decidim's MobilePhoneForm reads a falsy
        # deliver_code as a missing verification_code, so the handler is invalid
        # and PerformAuthorizationStep broadcasts :invalid.
        class RefusingGateway
          def initialize(_phone, _code, _context = {}); end

          def deliver_code = false
        end

        setup do
          @organization = create_organization
          host! @organization.host
          @komsiluk = build_komsiluk!(@organization)
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih::RegistrationsController.attempt_limiter_redis = FakeRedis.new
        end

        teardown do
          Decidim::Bih::RegistrationsController.attempt_limiter_redis = nil
          Decidim::Bih.phone_first_registration = false
        end

        # ------------------------------------------------------------- paths

        def base = Decidim::Bih.public_path("registracija")

        def pending_path = "#{base}/potvrda"

        def status_path = "#{base}/potvrda/status"

        def code_path = "#{base}/potvrda/kod"

        def resend_path = "#{base}/potvrda/ponovo"

        def account_path = Decidim::Bih.public_path("moj-nalog")

        def welcome_path = Decidim::Bih.public_path("dobrodosli")

        def phone_login_path = "/sr/users/sign_in"

        def sr(key) = I18n.t("decidim.bih.registrations.#{key}", locale: :sr)

        # ------------------------------------------------------------ helpers

        def registration_params(**overrides)
          {
            user: {
              name: "Mila Gradjanka",
              email: "mila-#{SecureRandom.hex(4)}@example.org",
              mobile_phone_number: PHONE,
              komsiluk_id: @komsiluk.id,
              tos_agreement: "1",
              newsletter: "0"
            }.merge(overrides)
          }
        end

        # Registers through the real endpoint and returns the account it opened.
        def register!(**overrides)
          params = registration_params(**overrides)
          post base, params: params
          Decidim::User.find_by(email: params[:user][:email], organization: @organization)
        end

        def authorization_for(user) = Decidim::Authorization.find_by(user:, name: "sms")

        def code_for(user) = authorization_for(user).verification_metadata["verification_code"]

        # The raw verify token is never stored, so a test that needs to tap the
        # link mints a fresh one for the same user and purpose — exactly what a
        # resend would have done.
        def live_token_for(user, phone: PHONE)
          Decidim::Bih::LoginToken.issue!(user:, purpose: "verify", phone:)
        end

        # Consumes the verify link in ANOTHER browser, which is what the phone
        # does while the desktop keeps polling.
        def tap_link_on_the_phone!(raw)
          other = open_session
          other.host! @organization.host
          # Decidim::Bih.magic_link_path, not a literal "/v/...": the short
          # root path exists only where the host enables it, and this harness
          # does not.
          other.post Decidim::Bih.magic_link_path(raw)
          other.assert_response :redirect, "the link must actually consume"
          other
        end

        # Puts THIS browser in the position of somebody who opened the resume
        # e-mail: e-mail-variant access to a registration it did not make.
        def hold_email_access!(user)
          reset!
          host! @organization.host
          get pending_path, params: { pending_token: Decidim::Bih::Registration::PendingAccess.mint_email(user) }
          follow_redirect!
        end

        # Walks the clock forward the way an open pending tab does: the page's
        # status poll keeps its session alive across the 24-hour link lifetime.
        # This generated host runs Decidim's default 30-minute cookie session
        # (a deployment may configure a far longer one — the reference host
        # runs a year), so a bare `travel` past half an hour would drop the
        # session variant here and test a refusal, not the expired page.
        def keep_the_page_open_for(duration)
          step = 20.minutes
          waited = 0
          while waited < duration
            travel step
            waited += step
            post status_path
            assert_response :success, "the poll that keeps the session alive stopped answering"
          end
        end

        def with_recording_gateway
          previous = Decidim.sms_gateway_service
          RecordingGateway.contexts = []
          Decidim.sms_gateway_service = RecordingGateway.name
          yield
        ensure
          Decidim.sms_gateway_service = previous
        end

        def with_refusing_gateway
          previous = Decidim.sms_gateway_service
          Decidim.sms_gateway_service = RefusingGateway.name
          yield
        ensure
          Decidim.sms_gateway_service = previous
        end

        # ---------------------------------------------------------- the form

        test "the form asks for a phone and two consents, and never for a password" do
          get base

          assert_response :success
          # Everything is scoped to this form: Decidim's own layout carries a
          # sign-in form whose fields are also user[email] and user[password],
          # and the point of the last two assertions is that REGISTRATION asks
          # for no password.
          assert_select "form#mi-registration-form" do
            assert_select "input[name='user[name]']"
            assert_select "input[name='user[email]']"
            assert_select "input[name='user[mobile_phone_number]']"
            assert_select "select[name='user[komsiluk_id]'] option[value=?]", @komsiluk.id.to_s
            assert_select "input[type=checkbox][name='user[tos_agreement]']"
            assert_select "input[type=checkbox][name='user[newsletter]']"
            assert_select "input[type=password]", count: 0
            assert_select "input[name='user[password]']", count: 0
          end
        end

        test "an invalid form comes back with the field errors and creates nothing" do
          assert_no_difference -> { Decidim::User.count } do
            post base, params: registration_params(email: "not-an-address", tos_agreement: "0")
          end

          assert_response :unprocessable_entity
          assert_includes response.body, sr("create.invalid")
          # What the citizen already typed survives the refusal.
          assert_select "input[name='user[mobile_phone_number]'][value=?]", PHONE
        end

        test "a number already confirmed on another account is refused on the form, not after the message" do
          verified = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: verified, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            granted_at: Time.current
          )

          post base, params: registration_params

          assert_response :unprocessable_entity
          assert_includes response.body, I18n.t("decidim.bih.registrations.errors.phone_taken", locale: :sr)
        end

        # --------------------------------------------------------- create

        test "registering lands on the pending page with no token in the URL and no session" do
          user = register!

          assert_redirected_to pending_path
          assert_not_nil user, "the account is open before the phone is proven"
          refute user.confirmed_at.nil?, "the account is usable immediately"

          follow_redirect!
          assert_response :success
          assert_includes response.body, Decidim::Bih::PhoneDisplay.mask(PHONE)
          refute_includes response.body, PHONE, "the number in clear never reaches the page"
          refute_includes response.body, code_for(user), "the page never shows the code"
          assert_match(/<details[^>]*data-mi-hidden-code/, response.body)
          refute_includes request.fullpath, "pending_token", "the session carries the token, not the URL"

          get account_path
          assert_response :redirect, "nothing is signed in until a phone is proven"
        end

        test "the pending page polls with a CSRF-protected POST, never a GET" do
          register!
          get pending_path

          assert_includes response.body, %(data-status-method="post")
          assert_includes response.body, "X-CSRF-Token"

          # The poll can sign this browser in, so the endpoint must not exist
          # as a GET at all (R-D4).
          begin
            get status_path
            assert_includes [404, 405], response.status, "the status poll is POST-only"
          rescue ActionController::RoutingError
            # Routing refused it outright, which is the same answer.
          end
        end

        test "a browser with no pending access cannot poll and cannot open the page" do
          register!
          reset!
          host! @organization.host

          get pending_path
          assert_redirected_to base

          post status_path
          assert_response :redirect
          refute_match(/"state"/, response.body)
        end

        test "the pending page and the status poll are never cached, referred or indexed" do
          register!

          get pending_path
          assert_pending_response_is_private

          post status_path
          assert_pending_response_is_private
        end

        # M8. The 302 that answers ?pending_token= is the response whose
        # REFERER carries a credential — the very URL the redirect exists to
        # get rid of. It has to be protected like the page it leads to, which
        # means protect_response cannot be the last before_action in the chain:
        # the two callbacks that redirect run before it.
        test "the redirects the pending page answers with are protected too" do
          user = register!
          reset!
          host! @organization.host

          get pending_path, params: { pending_token: Decidim::Bih::Registration::PendingAccess.mint_email(user) }
          assert_redirected_to pending_path
          assert_pending_response_is_private

          # The other redirecting callback: a browser with no pending access at
          # all is sent to the form, and that answer is no more indexable.
          reset!
          host! @organization.host
          get pending_path
          assert_redirected_to base
          assert_pending_response_is_private
        end

        def assert_pending_response_is_private
          cache_control = response.headers["Cache-Control"].to_s
          assert_includes cache_control, "no-store"
          assert_includes cache_control, "private",
                          "Decidim's caching disabler drops a raw set_header 'private'"
          assert_equal "strict-origin", response.headers["Referrer-Policy"]
          assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
        end

        # ------------------------------------------------------- typed code

        test "the code signs this browser in, lands on the welcome page and pays the 20 points" do
          user = register!

          perform_enqueued_jobs(only: AWARD_JOB) do
            post code_path, params: { verification_code: code_for(user) }
          end

          assert_redirected_to "#{welcome_path}?app=1"
          assert authorization_for(user).reload.granted?
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(user)
          assert_equal 20, goodwill_balance_for(user),
                       "verification 10 + komsiluk_selected 10, paid by the grant"

          get account_path
          assert_response :success, "this browser is signed in"
        end

        test "the fifth wrong code closes the challenge" do
          user = register!

          4.times do
            post code_path, params: { verification_code: "000000" }
            follow_redirect!
            assert_includes response.body, sr("confirm.wrong_code")
          end

          post code_path, params: { verification_code: "000000" }
          follow_redirect!
          assert_includes response.body, sr("confirm.exhausted")

          post code_path, params: { verification_code: code_for(user) }
          refute authorization_for(user).reload.granted?, "the budget outlives one code"
        end

        test "a browser holding one citizen's pending access cannot confirm another's code" do
          other = register!(email: "druga-#{SecureRandom.hex(3)}@example.org", mobile_phone_number: OTHER_PHONE)
          other_code = code_for(other)
          reset!
          host! @organization.host

          mine = register!
          post code_path, params: { verification_code: other_code }

          refute authorization_for(other).reload.granted?, "the other account is untouched"
          refute authorization_for(mine).reload.granted?, "and so is this one"
          get account_path
          assert_response :redirect
        end

        # ----------------------------------------------------------- resend

        test "a resend inside the first minute is refused and allowed once the minute has passed" do
          register!

          post resend_path
          assert_redirected_to pending_path
          follow_redirect!
          assert_includes response.body, sr("resend.too_soon")

          travel 61.seconds
          post resend_path
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
        end

        test "forcing SMS passes the channel restriction and the user down to the gateway" do
          user = register!
          travel 61.seconds

          with_recording_gateway do
            post resend_path, params: { channel: "sms" }

            assert_equal ["sms"], RecordingGateway.contexts.last[:channels]
            assert_equal user, RecordingGateway.contexts.last[:user]
            assert_equal @organization, RecordingGateway.contexts.last[:organization]
          end
        end

        test "the message budget runs out after five resends and says so" do
          register!

          Decidim::Bih::PhoneVerification::ResendBudget::MAX_RESENDS.times do
            travel 61.seconds
            post resend_path
            follow_redirect!
            assert_includes response.body, sr("resend.sent")
          end

          travel 61.seconds
          post resend_path
          follow_redirect!
          assert_includes response.body, sr("resend.exhausted")
        end

        # ---------------------------------------------------- change number

        test "changing the number voids the live link and takes a new one" do
          user = register!

          delete pending_path
          assert_redirected_to "#{pending_path}?promijeni=1"
          assert_equal 0, Decidim::Bih::LoginToken.where(user:, purpose: "verify", consumed_at: nil).count

          follow_redirect!
          assert_response :success
          assert_includes response.body, sr("pending.new_phone_label")

          post resend_path, params: { phone: "065 999 888" }
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
          assert_includes response.body, Decidim::Bih::PhoneDisplay.mask("+38765999888")
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for("+38765999888"),
                       authorization_for(user).reload.unique_id
          assert_equal 1, Decidim::Bih::LoginToken.where(user:, purpose: "verify", consumed_at: nil).count
        end

        # M7 / spec 5.4: the rewrite runs under the SAME row lock
        # PhoneVerification::Complete takes. Without it a link tapped in the
        # same instant can leave a granted row keyed on the new, unproven
        # number while CitizenPhone holds the old one.
        test "the number change rewrites the row under the user lock Complete takes" do
          user = register!
          locking = Decidim::User.find(user.id)
          locked = []
          locking.define_singleton_method(:with_lock) do |&block|
            locked << :held
            super(&block)
          end

          Decidim::Bih::Registration::PendingAccess.stub(:resolve, { user: locking, handoff: true }) do
            post resend_path, params: { phone: "065 999 888" }
          end

          assert_equal [:held], locked, "the rewrite and the budget reset happen inside the lock"
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for("+38765999888"),
                       authorization_for(user).reload.unique_id
        end

        test "a new number that is already confirmed elsewhere is refused" do
          verified = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: verified, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(OTHER_PHONE),
            granted_at: Time.current
          )
          user = register!

          post resend_path, params: { phone: OTHER_PHONE }
          follow_redirect!
          assert_includes response.body, sr("errors.phone_taken")
          refute_equal Decidim::Bih::SmsAuthorization.unique_id_for(OTHER_PHONE),
                       authorization_for(user).reload.unique_id
        end

        test "a new number somebody else is already verifying is refused" do
          other = register!(email: "druga-#{SecureRandom.hex(3)}@example.org", mobile_phone_number: OTHER_PHONE)
          reset!
          host! @organization.host
          user = register!

          post resend_path, params: { phone: OTHER_PHONE }
          follow_redirect!
          assert_includes response.body, sr("errors.phone_pending")
          refute_equal authorization_for(other).unique_id, authorization_for(user).reload.unique_id
        end

        test "a number that is not a number at all is refused before anything is sent" do
          register!

          post resend_path, params: { phone: "12" }
          follow_redirect!
          assert_includes response.body, sr("errors.phone_invalid")
        end

        test "only the browser that registered is offered the change-number button" do
          user = register!

          get pending_path
          assert_response :success
          assert_select "[data-mi-change]", 1, "this browser may point the verification at another phone"

          hold_email_access!(user)
          get pending_path
          assert_response :success
          # The button's only possible outcome from here is needs_session, and
          # once the link expires the shared body used to PROMOTE it to the
          # primary action under copy that says "enter your number again".
          assert_select "[data-mi-change]", 0
          assert_select "[data-mi-start-over]", 1, "start over is the honest way out it gets instead"
        end

        # ------------------------------------------------- the desktop hand-off

        test "the registering browser is handed the session once the link is tapped elsewhere" do
          user = register!
          raw = live_token_for(user)
          tap_link_on_the_phone!(raw)

          post status_path
          assert_response :success
          assert_equal "verified", response.parsed_body["state"]
          assert_equal "#{welcome_path}?app=1", response.parsed_body["next"]

          get account_path
          assert_response :success, "this browser is now signed in"

          # The hand-off happens exactly once: signing in reset the session, so
          # the next poll has no pending access left to spend.
          post status_path
          assert_response :redirect
        end

        test "status is pending before the link is tapped and expired once the code is old" do
          user = register!

          post status_path
          assert_equal "pending", response.parsed_body["state"]
          assert_nil response.parsed_body["next"]

          authorization_for(user).update!(
            verification_metadata: authorization_for(user).verification_metadata.merge("code_sent_at" => (Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute).ago)
          )
          post status_path
          assert_equal "expired", response.parsed_body["state"]
        end

        # Spec §10, mandatory regression: the hand-off is bounded in time.
        # handoff_window_open? is unit tested, but nothing asserted that the
        # POLL honours it — a regression that made hand_off_allowed? read
        # @handoff alone would pass every other test in this file.
        test "a hand-off asked for after the window closed answers where to sign in, and signs nobody in" do
          user = register!
          raw = live_token_for(user)
          # The tab stays open (polling, nothing to hand off yet) until the
          # link's last minute; the phone taps then, and the tab's next poll
          # only comes once the grace after expiry has passed as well.
          keep_the_page_open_for(Decidim::Bih::LoginToken::VERIFY_TTL - 1.minute)
          tap_link_on_the_phone!(raw)
          travel Decidim::Bih::Registration::PendingAccess::HANDOFF_GRACE + 2.minutes

          signed_in_before = user.reload.sign_in_count

          post status_path

          assert_response :success
          assert_equal "verified", response.parsed_body["state"]
          assert_equal phone_login_path, response.parsed_body["next"],
                       "past the window the honest answer is where to sign in, never a session"
          assert_nil signed_in_user_id, "this browser was not signed in"
          assert_equal signed_in_before, user.reload.sign_in_count

          get account_path
          assert_response :redirect, "and there is no session to show for it"
        end

        # Spec §10, mandatory regression: never switch another user's session.
        # The browser holding the pending token may already belong to somebody
        # else entirely — a shared computer, a family phone.
        test "a browser signed in as somebody else is never switched to the citizen it polls for" do
          pending_citizen = register!
          somebody_else = FactoryBot.create(:user, :confirmed, organization: @organization)
          # The phone taps first: Warden's test-mode login is global to the
          # run, so signing in here beforehand would sign the phone's own
          # browser in too and the link would be refused for the wrong reason.
          tap_link_on_the_phone!(live_token_for(pending_citizen))
          sign_in somebody_else

          post status_path

          assert_response :success
          assert_equal "verified", response.parsed_body["state"]
          assert_equal phone_login_path, response.parsed_body["next"],
                       "the refusal shape: where to sign in, not a hand-off"
          assert_equal somebody_else.id, signed_in_user_id,
                       "the session belongs to whoever was in it, and the poll does not take it"
        end

        # Spec §10: the poll can sign a browser in, so it is CSRF-protected.
        # Integration tests run with forgery protection off, which is exactly
        # why this one turns it back on around the poll alone.
        test "the poll refuses a POST with no CSRF token" do
          register!

          refused = with_forgery_protection { untokened_poll }

          assert_includes [:raised, 422], refused, "an untokened POST never reaches the poll"
          refute_match(/"state"/, response.body) unless refused == :raised
        end

        # Rails answers an untokened POST with a 422 where the test
        # environment renders exception responses, and by raising where it does
        # not. Both are the refusal; neither is the poll answering.
        def untokened_poll
          post status_path
          response.status
        rescue ActionController::InvalidAuthenticityToken
          :raised
        end

        def with_forgery_protection
          previous = ActionController::Base.allow_forgery_protection
          ActionController::Base.allow_forgery_protection = true
          yield
        ensure
          ActionController::Base.allow_forgery_protection = previous
        end

        # Warden's session entry is [[user_id], authenticatable_salt]; the id is
        # the part worth asserting. nil means no session was ever opened.
        def signed_in_user_id = session["warden.user.user.key"]&.first&.first

        # --------------------------------------------------- the e-mail token

        test "an e-mail pending token opens the page, cleans the URL and is never handed the session" do
          user = register!
          reset!
          host! @organization.host
          token = Decidim::Bih::Registration::PendingAccess.mint_email(user)

          get pending_path, params: { pending_token: token }
          assert_redirected_to pending_path, "the token is moved into the session and out of the URL"
          follow_redirect!
          assert_response :success
          assert_includes response.body, Decidim::Bih::PhoneDisplay.mask(PHONE)

          tap_link_on_the_phone!(live_token_for(user))

          post status_path
          assert_equal "verified", response.parsed_body["state"]
          assert_equal phone_login_path, response.parsed_body["next"],
                       "an unproven address is told where to sign in, never signed in"

          get account_path
          assert_response :redirect, "e-mail access never signs a browser in"
        end

        # Once the verify token is dead there is no number to name, nothing to
        # resend to and nothing a typed code could confirm — and this variant
        # cannot type a new number either. Every control that would only refuse
        # is gone, and the lead names the one thing that does work.
        test "the expired e-mail-variant page offers resend and start over, never a number change" do
          user = register!
          travel Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute
          hold_email_access!(user)

          get pending_path

          assert_response :success
          assert_includes response.body, sr("pending.expired_lead_start_over")
          refute_includes response.body, sr("pending.expired_lead"),
                          "the lead that says re-enter the number belongs to the variant that can"
          assert_select "[data-mi-resend]", 1, "the number is still on record, so a fresh link can be requested"
          assert_select "[data-mi-change]", 0
          assert_select "[data-mi-hidden-code]", 0
          assert_select "[data-mi-start-over]", 1
        end

        test "resend from the expired e-mail-variant page sends a fresh link to the number on record" do
          user = register!
          code_before = authorization_for(user).verification_metadata["verification_code"]
          travel Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute
          hold_email_access!(user)
          RecordingGateway.contexts = []

          with_recording_gateway do
            post resend_path
            follow_redirect!
          end

          assert_includes response.body, sr("resend.sent")
          assert_equal 1, RecordingGateway.contexts.size, "one message went out"
          assert_equal ["sms"], Array(RecordingGateway.contexts.first[:channels]), "and it was SMS-only, as every resend is"
          # The recording gateway mints no link (the real one does); Decidim's
          # own rewrite of the code on the pending row is what proves the send.
          refute_equal code_before, authorization_for(user).reload.verification_metadata["verification_code"],
                       "a fresh code was written to the pending row"
        end

        test "the expired session-variant page is unchanged: the number field and its own lead" do
          register!
          keep_the_page_open_for(Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute)

          get pending_path

          assert_response :success
          assert_includes response.body, sr("pending.expired_lead")
          refute_includes response.body, sr("pending.expired_lead_start_over")
          assert_select "[data-mi-new-phone]", 1, "the browser that registered gets the number field"
          assert_select "[data-mi-change]", 1
          assert_select "[data-mi-resend]", 1, "the number is still on record on either variant"
        end

        test "a pending token from another organization opens nothing" do
          user = register!
          other_organization = create_organization
          token = Decidim::Bih::Registration::PendingAccess.mint_email(user)
          reset!
          host! other_organization.host

          get pending_path, params: { pending_token: token }
          assert_response :redirect
          follow_redirect!
          follow_redirect! if response.redirect?
          assert_response :success
          assert_select "form#mi-registration-form"
          refute_includes response.body, Decidim::Bih::PhoneDisplay.mask(PHONE)
        end

        # ------------------------------- what only the registering browser may do

        test "the mailed link cannot point the verification at a different phone" do
          user = register!
          before = authorization_for(user).unique_id
          hold_email_access!(user)

          delete pending_path
          assert_redirected_to pending_path
          follow_redirect!
          assert_includes response.body, sr("pending.needs_session")
          assert_equal before, authorization_for(user).reload.unique_id
          assert_equal 1, Decidim::Bih::LoginToken.where(user:, purpose: "verify", consumed_at: nil).count,
                       "the live link is untouched, so nothing was redirected anywhere"

          post resend_path, params: { phone: "065 999 888" }
          assert_redirected_to pending_path
          follow_redirect!
          assert_includes response.body, sr("pending.needs_session")
          assert_equal before, authorization_for(user).reload.unique_id
        end

        test "the mailed link may still resend to the number already on the row" do
          user = register!
          hold_email_access!(user)
          travel 61.seconds

          post resend_path
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
                       authorization_for(user).reload.unique_id
        end

        test "the mailed link may still confirm the code that went to that number" do
          user = register!
          hold_email_access!(user)

          post code_path, params: { verification_code: code_for(user) }
          assert_redirected_to "#{welcome_path}?app=1"
          assert authorization_for(user).reload.granted?

          get account_path
          assert_response :success, "the code proves the phone, whichever token opened the page"
        end

        test "starting over throws the never-verified account away and returns to the form" do
          user = register!
          hold_email_access!(user)

          post "#{pending_path}/pocni-ispocetka"
          assert_redirected_to base
          follow_redirect!
          assert_response :success
          assert_select "form#mi-registration-form"
          assert_includes response.body, sr("pending.started_over")

          assert_nil Decidim::User.find_by(id: user.id)
          assert_nil Decidim::Authorization.find_by(decidim_user_id: user.id, name: "sms")
          assert_equal 0, Decidim::Bih::LoginToken.where(decidim_user_id: user.id).count
          assert_equal 0, Decidim::Bih::CitizenProfile.where(decidim_user_id: user.id).count
        end

        test "starting over is refused for an account somebody has already used" do
          user = register!
          user.update_column(:sign_in_count, 1) # rubocop:disable Rails/SkipsModelValidations
          hold_email_access!(user)

          post "#{pending_path}/pocni-ispocetka"
          assert_redirected_to pending_path
          follow_redirect!
          assert_includes response.body, sr("pending.start_over_refused")
          assert Decidim::User.exists?(user.id)
        end

        test "starting over takes the citizen's empty points account with it" do
          user = register!
          hold_email_access!(user)
          account = Decidim::Bih::Goodwill::Ledger.new.account_for(user)

          post "#{pending_path}/pocni-ispocetka"

          assert_redirected_to base
          assert_nil Decidim::User.find_by(id: user.id)
          assert_nil Decidim::Bih::Goodwill::Account.find_by(id: account.id),
                     "an account row whose owner is gone is an orphan nothing can ever reach"
        end

        # The guard used to run OUTSIDE the transaction and without a lock, so
        # two POSTs a moment apart both passed it and the second one met a row
        # that was already gone. It must be told the registration was reset —
        # which it was — instead of being handed a 500.
        test "the second of two concurrent start-overs is told it is already done" do
          user = register!
          vanishing = Decidim::User.find(user.id)
          vanishing.define_singleton_method(:lock!) { raise ActiveRecord::RecordNotFound }

          Decidim::Bih::Registration::PendingAccess.stub(:resolve, { user: vanishing, handoff: true }) do
            post "#{pending_path}/pocni-ispocetka"
          end

          assert_redirected_to base
          follow_redirect!
          assert_includes response.body, sr("pending.started_over")
          assert Decidim::User.exists?(user.id), "a request that never held the lock destroys nothing"
        end

        # The one thing only the LOCKED re-check can catch: the link tapped on
        # the phone an instant after the cheap unlocked guard read the row. The
        # grant is written from inside #lock!, on this same connection, so it
        # is there by the time the re-check looks — and the account must be
        # refused rather than thrown away with a proven phone on it.
        test "a grant that lands between the guard and the lock refuses the start over" do
          user = register!
          racing = Decidim::User.find(user.id)
          racing.define_singleton_method(:lock!) do
            Decidim::Authorization.where(decidim_user_id: id, name: "sms").update_all(granted_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
            super()
          end

          Decidim::Bih::Registration::PendingAccess.stub(:resolve, { user: racing, handoff: false }) do
            post "#{pending_path}/pocni-ispocetka"
          end

          assert_redirected_to pending_path
          assert_equal sr("pending.start_over_refused"), flash[:alert]
          assert Decidim::User.exists?(user.id), "an account with a proven phone is never thrown away"
          assert authorization_for(user).reload.granted?
        end

        test "a verified account never reaches start over at all" do
          user = register!
          hold_email_access!(user)
          Decidim::Bih::PhoneVerification::Complete.call(user:, phone: PHONE, session: {})

          post "#{pending_path}/pocni-ispocetka"
          assert_redirected_to phone_login_path
          assert Decidim::User.exists?(user.id)
        end

        # ------------------------------------------------------------- details

        test "the sign-up form stays findable while the pending page does not" do
          get base
          assert_response :success
          assert_nil response.headers["X-Robots-Tag"], "the front door is a page the platform wants found"

          register!
          get pending_path
          assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
        end

        # Behaviourally, not by inspecting the list: Rails compiles
        # filter_parameters into a single Regexp in a generated host, so the
        # symbol is not in there to be found.
        test "the pending token never reaches a request log" do
          filtered = ActiveSupport::ParameterFilter
                     .new(Rails.application.config.filter_parameters)
                     .filter("pending_token" => "a-signed-id")

          assert_equal "[FILTERED]", filtered["pending_token"]
        end

        test "a provider that refuses still leaves an account and a page to retry from" do
          user = nil
          with_refusing_gateway { user = register! }

          assert_not_nil user
          assert_redirected_to pending_path
          follow_redirect!
          assert_includes response.body, sr("create.delivery_failed")
          assert_not_nil authorization_for(user), "the pending row is what makes the page openable"
        end

        test "an abandoned claim on the new number is released instead of blocking it" do
          squatter = FactoryBot.create(:user, :confirmed, organization: @organization)
          stale = Decidim::Authorization.create!(
            user: squatter, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(OTHER_PHONE),
            granted_at: nil
          )
          stale.update_column(:created_at, (Decidim::Bih::LoginToken::VERIFY_TTL + 10.minutes).ago) # rubocop:disable Rails/SkipsModelValidations
          user = register!

          post resend_path, params: { phone: OTHER_PHONE }
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
          assert Decidim::Authorization.exists?(stale.id), "the squatter's row is their whole registration"
          assert_nil stale.reload.unique_id, "it simply no longer holds the number"
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(OTHER_PHONE),
                       authorization_for(user).reload.unique_id
        end

        test "re-typing the SAME number does not hand back the wrong-code guesses" do
          user = register!
          5.times { post code_path, params: { verification_code: "000000" } }
          follow_redirect!
          assert_includes response.body, sr("confirm.exhausted")

          post resend_path, params: { phone: PHONE }
          follow_redirect!
          assert_includes response.body, sr("resend.sent")

          post code_path, params: { verification_code: code_for(user) }
          follow_redirect!
          assert_includes response.body, sr("confirm.exhausted")
          refute authorization_for(user).reload.granted?,
                 "the same number is the same challenge, so the spent guesses stay spent"
        end

        test "a fresh number starts the attempt budget again" do
          user = register!
          5.times { post code_path, params: { verification_code: "000000" } }
          follow_redirect!
          assert_includes response.body, sr("confirm.exhausted")

          post resend_path, params: { phone: "065 999 888" }
          follow_redirect!
          post code_path, params: { verification_code: code_for(user) }

          assert authorization_for(user).reload.granted?, "changing the number really does hand back the code path"
        end

        # -------------------------------------------------------------- the copy

        # M3: the page may only promise a channel that can actually deliver,
        # and may only call the thing it sent a "link" while every channel in
        # the chain carries one. WhatsApp's AUTH template carries a code.
        def with_whatsapp_configured(&)
          Decidim::Bih::Config.stub(:whatsapp_phone_auth_configured?, true, &)
        end

        def sr_sent_to(key)
          I18n.t("decidim.bih.registrations.#{key}", locale: :sr, phone: Decidim::Bih::PhoneDisplay.mask(PHONE))
        end

        test "the form promises WhatsApp only where WhatsApp can deliver a code" do
          get base
          assert_includes response.body, sr("new.phone_hint")
          refute_includes response.body, sr("new.phone_hint_whatsapp")

          with_whatsapp_configured do
            get base
            assert_includes response.body, sr("new.phone_hint_whatsapp")
            refute_includes response.body, sr("new.phone_hint")
          end
        end

        test "the pending page says link while every channel carries one, and message once one does not" do
          register!

          get pending_path
          assert_includes response.body, sr_sent_to("pending.sent_to")
          assert_includes response.body, sr("pending.tap_hint")
          refute_includes response.body, sr("pending.tap_hint_whatsapp")

          with_whatsapp_configured do
            get pending_path
            assert_includes response.body, sr_sent_to("pending.sent_to_whatsapp")
            refute_includes response.body, sr_sent_to("pending.sent_to"),
                            "a WhatsApp recipient is not promised a link the message does not carry"
            assert_includes response.body, sr("pending.tap_hint_whatsapp")
          end
        end

        # M5: both dead ends used to be silent — the citizen landed on a form
        # that then refused their address, or on a login page with no reason
        # given.
        test "a dead link from the e-mail lands on the form and says why" do
          user = register!
          token = Decidim::Bih::Registration::PendingAccess.mint_email(user)
          other_organization = create_organization
          reset!
          host! other_organization.host

          get pending_path, params: { pending_token: token }

          assert_redirected_to base
          assert_equal sr("new.link_expired"), flash[:alert]
        end

        # The other half of the same refusal: a browser that is ITSELF
        # mid-registration keeps its own page. Its session variant is untouched
        # by whatever arrived in the URL, and "registruj se ponovo" on the form
        # would only dead-end on "this e-mail is taken" for the account it has
        # already opened.
        test "a dead e-mail link leaves a browser that is mid-registration on its own pending page" do
          register!
          other_organization = create_organization
          stranger = FactoryBot.create(:user, :confirmed, organization: other_organization)
          foreign_token = Decidim::Bih::Registration::PendingAccess.mint_email(stranger)

          get pending_path, params: { pending_token: foreign_token }

          assert_redirected_to pending_path
          assert_equal sr("new.link_expired"), flash[:alert]

          follow_redirect!
          assert_response :success, "its own session variant still opens the page"
          assert_select "[data-mi-change]", 1, "and still owns the number change"
        end

        test "a registration that is already finished says so before sending the citizen to sign in" do
          user = register!
          Decidim::Bih::PhoneVerification::Complete.call(user:, phone: PHONE, session: {})

          get pending_path

          assert_redirected_to phone_login_path
          assert_equal sr("pending.no_longer_pending"), flash[:alert]
        end

        # ------------------------------------------------- the released claim

        # I1. A citizen who mistypes their number as somebody else's real one
        # is exactly who the resume e-mail (spec 5.5) exists to rescue, and
        # ten minutes later that somebody registers. Their claim goes; their
        # ACCOUNT must not, or every pending route refuses their token, the
        # resume e-mail dead-ends, and the address they registered with is
        # taken by an account nobody can reach any more.

        def register_in_another_browser!(**overrides)
          other = open_session
          other.host! @organization.host
          params = registration_params(**overrides)
          other.post base, params: params
          Decidim::User.find_by(email: params[:user][:email], organization: @organization)
        end

        def capturing_the_log
          buffer = StringIO.new
          previous = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(buffer)
          yield
          buffer.string
        ensure
          Rails.logger = previous
        end

        test "a released claim leaves the citizen their account, their page and a way to a new number" do
          stranded = register!
          claim = authorization_for(stranded)
          keep_the_page_open_for(Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute)

          newcomer = register_in_another_browser!(email: "prava-#{SecureRandom.hex(3)}@example.org")
          assert_not_nil newcomer, "the number was free once the claim went stale"

          assert Decidim::User.exists?(stranded.id), "the account is not collateral"
          assert Decidim::Authorization.exists?(claim.id), "and neither is the row its token resolves through"
          assert_nil claim.reload.unique_id, "the claim is released, not destroyed"
          assert_nil claim.granted_at

          get pending_path
          assert_response :success, "the stranded citizen's own token still opens their page"
          assert_includes response.body, sr("pending.expired_lead")
          assert_select "[data-mi-new-phone]", 1

          post resend_path, params: { phone: "065 999 888" }
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for("+38765999888"), claim.reload.unique_id
        end

        test "a released citizen holding only the mailed link reaches start over" do
          stranded = register!
          travel Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute
          register_in_another_browser!(email: "prava-#{SecureRandom.hex(3)}@example.org")

          hold_email_access!(stranded)
          get pending_path

          assert_response :success
          assert_includes response.body, sr("pending.expired_lead_start_over")
          assert_select "[data-mi-start-over]", 1

          post "#{pending_path}/pocni-ispocetka"
          assert_redirected_to base
          assert_nil Decidim::User.find_by(id: stranded.id), "the address is free to register again"
        end

        test "releasing a claim logs the row id and nothing else about it" do
          claim = authorization_for(register!)
          travel Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute

          logged = capturing_the_log do
            register_in_another_browser!(email: "prava-#{SecureRandom.hex(3)}@example.org")
          end

          line = logged.lines.find { |entry| entry.include?("released stale pending sms authorization") }
          assert_not_nil line, "the release is recorded"
          assert_includes line, claim.id.to_s
          refute_includes line, PHONE
          refute_includes line, "65123456", "not the number in any shape"
          refute_includes line, claim.user.email
        end

        # ------------------------------------------------------- the referral

        # C1. The Warden after_set_user hook that attributes every Devise
        # sign-up's referral never fires for a one-step registrant:
        # CompletesPhoneAuthentication resets the session before the first
        # sign_in, so the code the invite link left there is gone by the time
        # the hook looks. POST /registracija is the moment this flow has, and
        # the welcome page's promise ("svaki komšija koji se registruje…")
        # depends on it being taken.
        REFERRAL_JOB = Decidim::Bih::Goodwill::ReferralRewardJob

        def invite_landing_path(nickname)
          "#{Decidim::Bih.public_path("zajednistvo")}?tab=pozovi&ref=#{CGI.escape(nickname)}"
        end

        def referral_for(user) = Decidim::Bih::Goodwill::Referral.find_by(invitee_id: user.id)

        test "a referral opened before registering is attributed at POST /registracija" do
          referrer = FactoryBot.create(:user, :confirmed, organization: @organization)

          get invite_landing_path(referrer.nickname)
          assert_response :success

          user = register!

          referral = referral_for(user)
          assert_not_nil referral, "the browser carried the code from the invite link into the registration"
          assert_equal referrer.id, referral.referrer_id
          assert_equal "pending", referral.status, "attribution is not payment"
          assert_equal 0, goodwill_balance_for(referrer), "nothing reaches the referrer at registration time"
        end

        test "the registered neighborhood and verified phone qualify the referral after the delay exactly once" do
          referrer = FactoryBot.create(:user, :confirmed, organization: @organization)
          get invite_landing_path(referrer.nickname)
          user = register!

          perform_enqueued_jobs(only: AWARD_JOB) do
            post code_path, params: { verification_code: code_for(user) }
          end

          authorization = authorization_for(user).reload
          assert authorization.granted?
          profile = Decidim::Bih::CitizenProfile.find_by!(user:, organization: @organization)
          assert_equal @komsiluk.id, profile.komsiluk_id
          referral = referral_for(user)
          perform_enqueued_jobs(only: REFERRAL_JOB, at: Time.current)
          assert_equal "pending", referral.reload.status,
                       "the grant enqueues the reward; it does not pay it immediately"
          assert_equal 0, goodwill_balance_for(referrer)

          available_at = [referral.created_at, authorization.granted_at].max + REFERRAL_JOB::REWARD_DELAY
          travel_to available_at + 1.minute do
            perform_enqueued_jobs(only: REFERRAL_JOB, at: Time.current)
            assert_equal "rewarded", referral.reload.status
            assert_equal 25, goodwill_balance_for(referrer)
            assert_no_difference -> { Decidim::Bih::Goodwill::Transaction.where(organization: @organization, reason: "referral").count } do
              REFERRAL_JOB.perform_now(user_id: user.id)
            end
          end
        end

        test "a second registration in the same browser does not clone the referral" do
          referrer = FactoryBot.create(:user, :confirmed, organization: @organization)
          get invite_landing_path(referrer.nickname)

          first = register!
          second = register!(email: "druga-#{SecureRandom.hex(3)}@example.org", mobile_phone_number: OTHER_PHONE)

          assert_not_nil referral_for(first)
          assert_nil referral_for(second), "the code was spent by the account it brought"
          assert_equal 1, Decidim::Bih::Goodwill::Referral.where(referrer_id: referrer.id).count
        end

        # ------------------------------------------------------- signed in

        test "a signed-in citizen is moved along instead of being offered the form again" do
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in citizen

          get base
          assert_response :redirect
          refute_match(/user\[mobile_phone_number\]/, response.body)
        end
      end

      # R-D6: the social entry point hands the phone over in the session and
      # nothing else. The concern's own rules are unit-tested against a fake
      # controller (test/controllers/concerns/.../social_registration_prefill_test.rb);
      # what only a Rails-backed run can show is that the override really
      # prepended itself onto the real controller and that the real form comes
      # back carrying the number.
      #
      # A controller test rather than an integration one because the session is
      # the input here: with CookieStore an integration test can only write the
      # session through a request that writes it, and the request that writes
      # this one is the HOST's omniauth callback (Task 9).
      class SocialRegistrationPrefillOnRegistrationFormTest < ActionController::TestCase
        tests Decidim::Bih::RegistrationsController
        # A controller test runs no middleware, so Warden has to be injected —
        # Decidim reaches for current_user on every request it logs.
        include ::Devise::Test::ControllerHelpers

        PHONE = "+38765123456"

        setup do
          @routes = Decidim::Bih::Engine.routes
          @organization = create_organization
          @komsiluk = build_komsiluk!(@organization)
          @request.host = @organization.host
          @request.env["decidim.current_organization"] = @organization
          Decidim::Bih.phone_first_registration = true
        end

        teardown { Decidim::Bih.phone_first_registration = false }

        def prefill_context(**overrides)
          {
            "phone" => PHONE,
            "organization_id" => @organization.id,
            "expires_at" => 10.minutes.from_now.iso8601
          }.merge(overrides.stringify_keys)
        end

        test "the override is prepended onto the one-step registration controller" do
          assert_includes Decidim::Bih::RegistrationsController.ancestors,
                          Decidim::Bih::SocialRegistrationPrefill
        end

        test "a prefill context in the session fills the phone field in" do
          get :new, session: { Decidim::Bih::SocialRegistrationPrefill::SESSION_KEY => prefill_context }

          assert_response :success
          assert_select "input[name='user[mobile_phone_number]'][value=?]", PHONE
        end

        test "without a prefill context the form is exactly as it was" do
          get :new

          assert_response :success
          assert_select "input[name='user[mobile_phone_number]']"
          assert_select "input[name='user[mobile_phone_number]'][value=?]", PHONE, count: 0
        end
      end
    end
  end
end
