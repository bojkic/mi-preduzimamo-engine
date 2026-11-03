# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The "Link je poslan" page: the citizen has a pending sms authorization
      # and a verification link on the way. The page never shows the code, it
      # masks the number, it polls for the desktop hand-off, and it keeps the
      # typed-code path behind a toggle for feature phones.
      class PhoneVerificationPageTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveSupport::Testing::TimeHelpers

        PHONE = "+38765123456"

        # Mirrors the double in the AttemptLimiter unit test. `eval` is the
        # Redis client's EVAL command (the atomic increment-and-set-TTL Lua
        # script), not Ruby's Kernel#eval — no Ruby string is evaluated here.
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

        # A store that is simply down. The limiter is fail-closed, so the code
        # path must close — but the citizen must be told the truth about why.
        class BrokenRedis
          def get(*) = raise(IOError, "down")

          def eval(*, **) = raise(IOError, "down")

          def del(*) = raise(IOError, "down")
        end

        # Counts correctly but always reads back zero. Stands in for the race
        # a separate read opens: two resends that both read the count before
        # either has written one both believe there is budget left. Only a
        # decision made on the value the INCR returned survives this.
        class LyingRedis < FakeRedis
          def get(_key) = "0"
        end

        # Stands in for Decidim.sms_gateway_service so a test can see the
        # context the form handed the gateway — that is where the forced-SMS
        # channel restriction has to arrive.
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

        # The gateway that answers "no". Decidim's MobilePhoneForm treats a
        # falsy deliver_code as a missing verification_code, so the form is
        # invalid and PerformAuthorizationStep broadcasts :invalid — the
        # resend failure path.
        class RefusingGateway
          class << self
            attr_accessor :calls
          end
          self.calls = 0

          def initialize(_phone, _code, _context = {})
            self.class.calls += 1
          end

          def deliver_code = false
        end

        setup do
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in @citizen
          Decidim::Bih.phone_first_registration = true
          # The harness host has no Redis, and AttemptLimiter is fail-closed
          # (no Redis => exhausted?), which would close the code path for every
          # test here. The controller therefore takes its Redis through a class
          # attribute the test can swap for an in-memory double.
          @fake_redis = FakeRedis.new
          Decidim::Bih::PhoneVerificationController.attempt_limiter_redis = @fake_redis
        end

        teardown do
          Decidim::Bih::PhoneVerificationController.attempt_limiter_redis = nil
          Decidim::Bih.phone_first_registration = false
        end

        def pending!(code: "123456", sent_at: Time.current, user: @citizen)
          authorization = Decidim::Authorization.create!(
            user:, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            verification_metadata: { "verification_code" => code, "code_sent_at" => sent_at },
            granted_at: nil
          )
          Decidim::Bih::LoginToken.issue!(user:, purpose: "verify", phone: PHONE)
          @authorization = authorization if user == @citizen
          authorization
        end

        # The real-world shape a phone write failure leaves behind (see
        # PhoneVerification::Complete's #record_phone! comment): a granted
        # authorization with no verification_metadata (Decidim clears it on
        # grant) and no decidim_bih_citizen_phones row.
        def granted_without_phone!
          authorization = Decidim::Authorization.create!(
            user: @citizen, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current },
            granted_at: nil
          )
          authorization.update!(granted_at: 1.week.ago, verification_metadata: {})
          @authorization = authorization
        end

        def page_path = Decidim::Bih.public_path("verifikacija/telefon")

        def komsiluk_setup_path = "#{Decidim::Bih.public_path("komsiluk")}?setup=1"

        def sr(key) = I18n.t("decidim.bih.phone_verification.#{key}", locale: :sr)

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
          RefusingGateway.calls = 0
          Decidim.sms_gateway_service = RefusingGateway.name
          yield
        ensure
          Decidim.sms_gateway_service = previous
        end

        # ---------------------------------------------------------------- show

        test "the page shows a masked number and an always-visible code entry" do
          pending!
          get page_path
          assert_response :success
          assert_includes response.body, Decidim::Bih::PhoneDisplay.mask(PHONE)
          # The element itself, not the string: the poll script also mentions
          # the attribute, so matching the raw body proves nothing. `open` is
          # part of the contract (R-D9) — the citizen who never got the link
          # must see the field, not have to find a toggle first.
          assert_match(/<details[^>]*data-mi-hidden-code[^>]*open/, response.body)
          assert_includes response.body, sr("show.have_code")
          assert_includes response.body, "mi-verification-code", "the code field is on the page"
          refute_includes response.body, PHONE, "the number in clear never reaches the page"
          refute_includes response.body, "123456", "neither the code nor the number's tail is rendered"
          refute_includes response.body, "[phone", "the log mask is never rendered to a citizen"
          assert_includes response.body, sr("show.resend"), "a live link can be sent again"
        end

        # WhatsApp is named in the code-entry copy only where WhatsApp can
        # actually deliver a code (R-D9). The partial is shared, so delivery
        # D's registration pending page inherits the same branch.
        test "the code entry names WhatsApp only where WhatsApp can deliver a code" do
          pending!

          get page_path
          assert_includes response.body, sr("show.have_code")
          refute_includes response.body, sr("show.have_code_whatsapp")

          Decidim::Bih::Config.stub(:whatsapp_phone_auth_configured?, true) do
            get page_path
          end
          assert_includes response.body, sr("show.have_code_whatsapp")
          refute_includes response.body, sr("show.have_code"),
                          "the two labels are alternatives, never both"
        end

        test "without a live link the page says the link expired instead of masking nothing" do
          pending!
          Decidim::Bih::LoginToken.invalidate_live!(user: @citizen, purpose: "verify")

          get page_path
          assert_response :success
          assert_match(/data-mi-lead>\s*#{Regexp.escape(sr("show.expired_lead"))}/, response.body)
          refute_match(/<details[^>]*data-mi-hidden-code/, response.body, "there is no code left to type")
          refute_includes response.body, "mi-verification-code"
          refute_includes response.body, "[phone"
          # The number is still on record (the dead token keeps it), so the
          # page offers a fresh link as well as re-entering the number.
          assert_includes response.body, sr("show.change_number")
          assert_includes response.body, sr("show.resend")
        end

        # The script's runtime is out of reach here, but its stop condition is
        # not: one 502 blip must not permanently strand a desktop citizen who
        # is still about to tap the link on the phone.
        test "the poll gives up on a lost session, not on a transient server error" do
          pending!
          get page_path

          refute_includes response.body, "!r.ok ||", "any non-2xx must not be terminal"
          assert_includes response.body, "r.status === 401", "a lost session is"
          assert_includes response.body, "if (!r.ok) return null;", "a 5xx keeps the poll alive"
        end

        # Twelve polls a minute against a per-session budget of thirty, and a
        # 429 slows the page down instead of spending the rest of that budget
        # on rejections. A fixed interval cannot do the second thing, so the
        # absence of setInterval is part of the contract.
        test "the poll asks every five seconds and backs off when it is throttled" do
          pending!
          get page_path

          assert_includes response.body, "BASE_INTERVAL_MS = 5000"
          assert_includes response.body, "MAX_INTERVAL_MS = 60000"
          assert_includes response.body, "r.status === 429"
          assert_includes response.body, "Math.min(interval * 2, MAX_INTERVAL_MS)"
          refute_includes response.body, "setInterval("
          # A fetch that resolves after the tab was hidden re-arms the chain
          # through the same start(), so the visibility check has to live
          # there and not only in the visibilitychange handler.
          assert_includes response.body, "!done && !timer && !document.hidden"
        end

        test "without a pending authorization the page sends the citizen to the phone form" do
          get page_path
          assert_redirected_to Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr)
        end

        # ------------------------------------------------------------ reverify

        test "a granted authorization with a saved phone still redirects onward as before" do
          granted_without_phone!
          Decidim::Bih::VerifiedPhone.synchronize!(user: @citizen, organization: @organization, phone: PHONE)

          get page_path
          assert_redirected_to komsiluk_setup_path
        end

        test "a granted authorization with no saved phone renders a phone-input reverify page instead of redirecting" do
          granted_without_phone!

          get page_path
          assert_response :success
          assert_includes response.body, sr("show.reverify_lead")
          assert_includes response.body, sr("show.reverify_phone_label"), "the page asks for the number, not a code"
          assert_includes response.body, sr("show.reverify_submit")
          assert_includes response.body, sr("show.reverify_change"), "change-number is offered as the secondary escape hatch"
          refute_includes response.body, sr("show.resend"), "resend must not act on an already-granted authorization"
          refute_includes response.body, PHONE, "the number in clear never reaches the page"
        end

        test "the reverify page's status poll reports expired, never verified, so a poll tick cannot redirect it away" do
          granted_without_phone!

          get "#{page_path}/status.json"
          assert_equal "expired", response.parsed_body["state"]
          assert_nil response.parsed_body["next"]
        end

        # J3: reverify must NEVER destroy the grant. It records the phone
        # against the ALREADY-granted authorization and finishes exactly like
        # the typed-code path (same route, same PWA app=1 marker).
        test "reverify with the exact confirmed number saves it and finishes without destroying the grant" do
          granted_without_phone!
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)

          post "#{page_path}/kod", params: { phone: PHONE }
          assert_redirected_to "#{komsiluk_setup_path}&app=1"
          assert @authorization.reload.granted?, "reverify must never destroy the existing grant"
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "reverify matches a local-format number against an internationally-confirmed one" do
          granted_without_phone! # unique_id_for(PHONE), PHONE = "+38765123456"
          local_format = "0#{PHONE.delete_prefix("+387")}" # -> "065123456"

          post "#{page_path}/kod", params: { phone: local_format }
          assert_redirected_to "#{komsiluk_setup_path}&app=1"
          assert @authorization.reload.granted?
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "reverify with the wrong number five times exhausts the attempt budget without touching the grant" do
          granted_without_phone!

          5.times { post "#{page_path}/kod", params: { phone: "+38765999999" } }
          follow_redirect!
          assert_includes response.body, sr("confirm.exhausted")
          refute_includes response.body, sr("show.reverify_submit"),
                          "an exhausted budget takes the phone form away, it does not merely refuse it"
          assert @authorization.reload.granted?, "exhaustion must never destroy the grant"
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        # J4: the grant already stood before the request, so Complete's
        # result.granted? is true whatever happened to the phone row —
        # including the silent record_phone! failure this page exists to
        # recover from. Keying success off it would tell the citizen "saved"
        # and send them away with nothing saved, twice.
        test "reverify says the number was not saved when the phone row still fails to write" do
          granted_without_phone!
          store_down = ->(*) { raise IOError, "phone store down" }

          Decidim::Bih::CitizenPhoneRecord.stub(:find_or_initialize_by, store_down) do
            post "#{page_path}/kod", params: { phone: PHONE }
          end

          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("confirm.reverify_not_saved")
          refute_includes response.body, sr("show.reverify_saved"), "nothing was saved, so nothing may say so"
          assert_includes response.body, sr("show.reverify_submit"), "the citizen stays on the page and can try again"
          assert @authorization.reload.granted?, "a failed phone write must never cost the grant"
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        # The AttemptLimiter is fail-closed, so a Redis outage reads as
        # "exhausted". On the reverify page that would hide the phone form and
        # leave the citizen with nothing but "I no longer have that number" —
        # offering only the destructive action for our own outage.
        test "a reverify page whose attempt counter is down keeps the phone form and says so" do
          granted_without_phone!
          Decidim::Bih::PhoneVerificationController.attempt_limiter_redis = BrokenRedis.new

          get page_path
          assert_response :success
          assert_includes response.body, sr("show.reverify_unavailable")
          refute_includes response.body, sr("confirm.unavailable"),
                          "the code page's copy tells them to tap a link this page does not have"
          assert_includes response.body, sr("show.reverify_submit"),
                          "our outage must not take the way forward away"
          assert_includes response.body, sr("show.reverify_change"),
                          "the escape hatch stays available, but not as the only option"
          refute_includes response.body, sr("show.resend"), "there is still nothing to resend on a granted row"
        end

        test "a single wrong reverify number is refused with the mismatch copy, grant intact" do
          granted_without_phone!

          post "#{page_path}/kod", params: { phone: "+38765999999" }
          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("confirm.reverify_mismatch")
          assert @authorization.reload.granted?
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "resend is refused during reverify, without destroying the grant" do
          granted_without_phone!

          post "#{page_path}/ponovo"
          assert_redirected_to "#{page_path}?locale=sr"
          assert @authorization.reload.granted?
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "cross-user: another citizen's reverify post cannot touch this citizen's authorization" do
          granted_without_phone! # @citizen (A): granted, no phone saved

          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          other_phone = "+38765111222"
          other_auth = Decidim::Authorization.create!(
            user: other, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(other_phone),
            verification_metadata: { "verification_code" => "999999", "code_sent_at" => Time.current },
            granted_at: nil
          )
          other_auth.update!(granted_at: 1.week.ago, verification_metadata: {})

          sign_out @citizen
          sign_in other

          post "#{page_path}/kod", params: { phone: PHONE }
          assert_redirected_to "#{page_path}?locale=sr"

          assert other_auth.reload.granted?, "B's own authorization is untouched"
          assert_nil Decidim::Bih::CitizenPhone.for(other), "A's number must never match B's grant"
          assert @authorization.reload.granted?, "A's authorization is untouched by B's request"
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen), "A's phone stays unsaved"
        end

        test "changing the number from the reverify page destroys the authorization and restarts phone verification" do
          granted_without_phone!

          delete page_path
          assert_redirected_to Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr)
          assert_nil Decidim::Authorization.find_by(user: @citizen, name: "sms")
        end

        # The page's own redirect and the desktop poll's "next" must be the
        # same answer. With phone-first off the host registers no :sms
        # workflow, so the onboarding chain's first step is a 404 there and
        # the account checklist is the only honest destination — the shared
        # CompletesPhoneAuthentication helper is what knows that.
        test "with phone-first registration off the page and the poll agree on the account checklist" do
          Decidim::Bih.phone_first_registration = false
          granted_without_phone!
          Decidim::Bih::VerifiedPhone.synchronize!(user: @citizen, organization: @organization, phone: PHONE)
          checklist = "#{Decidim::Bih.public_path("moj-nalog")}?locale=sr#zavrsi-nalog"

          get page_path
          assert_redirected_to "#{Decidim::Bih.public_path("moj-nalog")}?locale=sr#zavrsi-nalog"

          get "#{page_path}/status.json"
          assert_equal "verified", response.parsed_body["state"]
          assert_equal checklist, response.parsed_body["next"],
                       "the poll must not send a desktop session somewhere the page would not"
        end

        # Every request here is SIGNED IN, which is the case that used to lose
        # `private`: Decidim's Headers::HttpCachingDisabler populates the
        # response's cache_control API in an earlier before_action, and at
        # commit time ActionDispatch merges that API over whatever a raw
        # set_header wrote — shipping "no-cache, no-store" and dropping the
        # directive that keeps the masked number out of a shared proxy. The
        # assertion is on the wire header for exactly that reason.
        test "the page and the status endpoint are never cached, referred or indexed" do
          pending!
          [page_path, "#{page_path}/status.json"].each do |path|
            get path
            cache_control = response.headers["Cache-Control"].to_s
            assert_includes cache_control, "no-store", path
            assert_includes cache_control, "private",
                            "#{path}: a signed-in response must keep `private` (#{cache_control})"
            assert_equal "strict-origin", response.headers["Referrer-Policy"], path
            assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"], path
          end
        end

        # The shared body only hides the change-number button where the page
        # says it may not be used (delivery D's e-mail variant). A's citizen
        # has a session and Decidim's own SMS form to go back to, so the button
        # stays — and the default of the seam that decides it is "allowed".
        test "the signed-in page still offers the change-number button" do
          pending!

          get page_path

          assert_response :success
          assert_select "[data-mi-change]", 1
        end

        # -------------------------------------------------------------- status

        test "status is pending, then verified with the next step after the link is consumed" do
          pending!
          get "#{page_path}/status.json"
          assert_equal "pending", response.parsed_body["state"]

          Decidim::Bih::PhoneVerification::Complete.call(user: @citizen, phone: PHONE)
          get "#{page_path}/status.json"
          assert_equal "verified", response.parsed_body["state"]
          assert_equal komsiluk_setup_path, response.parsed_body["next"]
        end

        test "status is expired once the code is older than its lifetime" do
          pending!(sent_at: (Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute).ago)
          get "#{page_path}/status.json"
          assert_equal "expired", response.parsed_body["state"]
        end

        test "a signed-out visitor gets a sign-in redirect, not the status JSON" do
          pending!
          sign_out @citizen

          get "#{page_path}/status.json"
          assert_response :redirect
          refute_match(/"state"/, response.body)
        end

        test "another citizen can neither read nor confirm this citizen's challenge" do
          pending!
          sign_in FactoryBot.create(:user, :confirmed, organization: @organization)

          get "#{page_path}/status.json"
          assert_equal "expired", response.parsed_body["state"]
          assert_nil response.parsed_body["next"]

          post "#{page_path}/kod", params: { verification_code: "123456" }
          assert_redirected_to Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr)
          refute @authorization.reload.granted?
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        # ------------------------------------------------------------- confirm

        # The finish runs through CompletesPhoneAuthentication, the one place a
        # proven phone turns into a destination, so the typed code lands where
        # a tapped magic link lands — including the app=1 PWA install marker.
        test "a correct code grants, records the phone and redirects to the next step" do
          pending!
          post "#{page_path}/kod", params: { verification_code: "123456" }
          assert_redirected_to "#{komsiluk_setup_path}&app=1"
          assert @authorization.reload.granted?
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "an expired code is refused even when correct" do
          pending!(sent_at: (Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute).ago)
          post "#{page_path}/kod", params: { verification_code: "123456" }
          refute @authorization.reload.granted?
        end

        test "the fifth wrong code closes the challenge and a resend does not reopen it" do
          pending!(sent_at: 2.minutes.ago)
          5.times { post "#{page_path}/kod", params: { verification_code: "000000" } }

          post "#{page_path}/ponovo"
          fresh_code = @authorization.reload.verification_metadata["verification_code"]
          refute_equal "123456", fresh_code, "the resend really did mint a new code"

          post "#{page_path}/kod", params: { verification_code: fresh_code }
          refute @authorization.reload.granted?, "the attempt budget outlives one code"
          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("confirm.exhausted")
        end

        test "changing the number starts a fresh attempt budget" do
          pending!
          5.times { post "#{page_path}/kod", params: { verification_code: "000000" } }
          delete page_path
          pending!

          post "#{page_path}/kod", params: { verification_code: "000000" }
          follow_redirect!
          assert_includes response.body, sr("confirm.wrong_code")
          refute_includes response.body, sr("confirm.exhausted")
        end

        test "a store outage says the code path is unavailable, not that you guessed too often" do
          pending!
          Decidim::Bih::PhoneVerificationController.attempt_limiter_redis = BrokenRedis.new

          post "#{page_path}/kod", params: { verification_code: "123456" }
          refute @authorization.reload.granted?, "the limiter stays fail-closed"
          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("confirm.unavailable")
          refute_includes response.body, sr("confirm.exhausted")
        end

        # -------------------------------------------------------------- resend

        test "a resend inside the first minute is refused, and allowed once the minute has passed" do
          pending!

          post "#{page_path}/ponovo"
          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("resend.too_soon")

          travel 61.seconds
          post "#{page_path}/ponovo"
          follow_redirect!
          assert_includes response.body, sr("resend.sent")
        end

        test "every resend is SMS-only, forced or not" do
          pending!(sent_at: 2.minutes.ago)

          with_recording_gateway do
            post "#{page_path}/ponovo", params: { channel: "sms" }
            assert_equal ["sms"], RecordingGateway.contexts.last[:channels]
            # The magic link the gateway mints is user-bound (see
            # sms_gateway_context_override.rb), so a context missing :user is
            # exactly the shape of the "resend never sends" defect: no link,
            # no send.
            assert_equal @citizen, RecordingGateway.contexts.last[:user]
            assert_equal @organization, RecordingGateway.contexts.last[:organization]

            travel 61.seconds
            # A resend means the first chain has already tried Viber and WhatsApp
            # for this number: repeating them bills those legs again and leaves the
            # citizen holding two messages with two codes, the older one dead
            # (review 2026-09-07, lane 1 H3).
            post "#{page_path}/ponovo"
            assert_equal ["sms"], RecordingGateway.contexts.last[:channels],
                         "a plain resend is SMS-only too"
            assert_equal @citizen, RecordingGateway.contexts.last[:user]
            assert_equal @organization, RecordingGateway.contexts.last[:organization]
          end
        end

        # E1: the 60-second cooldown caps the rate and nothing else. Rotating
        # sessions against the same live token would otherwise buy a paid
        # message a minute — roughly fifteen per quarter hour — aimed at
        # whatever number the citizen typed, which need not be their own.
        test "the sixth message for one challenge is refused, and never reaches the gateway" do
          pending!(sent_at: 2.minutes.ago)

          with_recording_gateway do
            5.times do
              post "#{page_path}/ponovo"
              travel 61.seconds
            end

            assert_equal 5, RecordingGateway.contexts.size, "five messages are the whole budget"

            post "#{page_path}/ponovo"
            assert_equal 5, RecordingGateway.contexts.size, "the sixth never reaches the gateway"
          end

          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("resend.exhausted")
          refute_includes response.body, sr("resend.too_soon"), "the minute had passed; the budget had not"
        end

        # The budget is spent and judged in one step. A read taken before the
        # write is a race two tabs can win together, and the thing they win is
        # a paid message each.
        test "the budget is decided on the increment, not on a separate read" do
          pending!(sent_at: 2.minutes.ago)
          Decidim::Bih::PhoneVerificationController.attempt_limiter_redis = LyingRedis.new

          with_recording_gateway do
            6.times do
              post "#{page_path}/ponovo"
              travel 61.seconds
            end

            assert_equal 5, RecordingGateway.contexts.size,
                         "a counter that reads back zero must not buy a sixth message"
          end

          follow_redirect!
          assert_includes response.body, sr("resend.exhausted")
        end

        # Forcing SMS is the same paid message through a different channel, so
        # it spends from the same budget.
        test "forced-SMS resends spend the same budget as ordinary ones" do
          pending!(sent_at: 2.minutes.ago)

          with_recording_gateway do
            5.times do
              post "#{page_path}/ponovo", params: { channel: "sms" }
              travel 61.seconds
            end

            post "#{page_path}/ponovo"
            assert_equal 5, RecordingGateway.contexts.size
          end

          follow_redirect!
          assert_includes response.body, sr("resend.exhausted")
        end

        # Money direction: if we cannot count the messages we do not send one.
        test "a resend whose budget cannot be counted is refused and says so" do
          pending!(sent_at: 2.minutes.ago)
          Decidim::Bih::PhoneVerificationController.attempt_limiter_redis = BrokenRedis.new

          with_recording_gateway do
            post "#{page_path}/ponovo"
            assert_empty RecordingGateway.contexts, "an uncountable message is not sent"
          end

          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("resend.unavailable")
          refute_includes response.body, sr("resend.exhausted"),
                          "our outage must not be reported as the citizen's spending"
        end

        # The way out that stays open: a new number is a new authorization row,
        # so it is a new budget — and the number it sends to is one the citizen
        # just typed again.
        test "changing the number starts a fresh resend budget" do
          pending!(sent_at: 2.minutes.ago)
          5.times do
            post "#{page_path}/ponovo"
            travel 61.seconds
          end

          delete page_path
          pending!(sent_at: 2.minutes.ago)

          with_recording_gateway do
            post "#{page_path}/ponovo"
            assert_equal 1, RecordingGateway.contexts.size
          end

          follow_redirect!
          assert_includes response.body, sr("resend.sent")
          refute_includes response.body, sr("resend.exhausted")
        end

        # The link is minted before the message goes out (the SMS text carries
        # it), so a failed send has already voided the one the citizen is
        # holding. Saying only "sending failed" would leave them tapping a
        # dead link.
        test "a failed resend says the previous link no longer works" do
          pending!(sent_at: 2.minutes.ago)

          with_refusing_gateway do
            post "#{page_path}/ponovo"
            assert_equal 1, RefusingGateway.calls
          end

          assert_redirected_to "#{page_path}?locale=sr"
          follow_redirect!
          assert_includes response.body, sr("resend.failed")
          assert_includes response.body, "prethodni link"
        end

        # -------------------------------------------------------------- change

        test "changing the number voids the live link and returns to the phone form" do
          pending!
          delete page_path
          assert_redirected_to Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr)
          assert_nil Decidim::Authorization.find_by(user: @citizen, name: "sms")
          assert_equal 0, Decidim::Bih::LoginToken.where(user: @citizen, purpose: "verify", consumed_at: nil).count
        end

        # ------------------------------------------- decidim's own code screen

        test "decidim's own code page redirects here, carrying the redirect_url" do
          pending!
          get "/sr/sms/authorizations/edit"
          assert_redirected_to page_path

          get "/sr/sms/authorizations/edit?redirect_url=%2Fprocesses%2Fx"
          assert_equal "/processes/x", query_param(response.location, "redirect_url")
        end

        # The parameter on Decidim's own page is attacker-controlled, and this
        # override hands it to the engine page, which puts it in that page's
        # forms and in the poll's "next". Forwarding it unvetted would plant an
        # off-site destination there; Decidim::SafeRedirect is what drops it.
        test "an off-site redirect_url is dropped before it reaches our page" do
          pending!

          get "/sr/sms/authorizations/edit?redirect_url=%2F%2Fevil.example"
          assert_redirected_to page_path
          assert_nil query_param(response.location, "redirect_url")

          get "/sr/sms/authorizations/edit?redirect_url=https%3A%2F%2Fevil.example%2Fx"
          assert_nil query_param(response.location, "redirect_url")

          patch "/sr/sms/authorizations", params: { redirect_url: "//evil.example" }
          assert_nil query_param(response.location, "redirect_url")
        end

        test "decidim's own code POST redirects here too" do
          pending!
          patch "/sr/sms/authorizations", params: { verification_code: "123456" }
          assert_redirected_to page_path
          refute @authorization.reload.granted?, "the stock code POST never grants under phone-first"
        end

        test "decidim's own destroy voids the live verify link" do
          pending!
          delete "/sr/sms/authorizations"
          assert_nil Decidim::Authorization.find_by(user: @citizen, name: "sms")
          assert_equal 0, Decidim::Bih::LoginToken.where(user: @citizen, purpose: "verify", consumed_at: nil).count
        end

        test "with phone-first off decidim's own code page is left exactly as it was" do
          pending!
          Decidim::Bih.phone_first_registration = false

          get "/sr/sms/authorizations/edit"
          assert_response :success, "the stock page renders instead of redirecting to ours"
        end

        # ---------------------------------------------------------- redirect_url

        # The mid-journey location still beats the onboarding chain; it simply
        # carries the same app=1 marker every finished verification carries.
        # The status poll answers the desktop tab, which is not the device the
        # link was tapped on, so its "next" stays the bare destination.
        test "a safe redirect_url survives the verification" do
          pending!
          post "#{page_path}/kod", params: { verification_code: "123456", redirect_url: "/processes/x" }
          assert_redirected_to "/processes/x?app=1"

          get "#{page_path}/status.json", params: { redirect_url: "/processes/x" }
          assert_equal "verified", response.parsed_body["state"]
          assert_equal "/processes/x", response.parsed_body["next"]
        end

        test "an off-site redirect_url is dropped in favour of the onboarding chain" do
          pending!
          post "#{page_path}/kod", params: { verification_code: "123456", redirect_url: "//evil.example" }
          assert_redirected_to "#{komsiluk_setup_path}&app=1"
        end

        # ---------------------------------------------------------------- logs

        # Rails compiles config.filter_parameters into one Regexp, so assert on
        # the behaviour the engine actually buys: a logged parameter hash comes
        # out scrubbed.
        test "the one-time codes are filtered out of the request log" do
          filtered = ActiveSupport::ParameterFilter
                     .new(Rails.application.config.filter_parameters)
                     .filter("verification_code" => "123456", "otp_code" => "654321",
                             "entry_code" => "ABC123", "phone" => PHONE,
                             "mobile_phone_number" => PHONE, "komsiluk" => "Dvorovi")

          assert_equal "[FILTERED]", filtered["verification_code"]
          assert_equal "[FILTERED]", filtered["otp_code"]
          assert_equal "[FILTERED]", filtered["entry_code"]
          # The reverify form posts the number itself, and Decidim's own SMS
          # form posts mobile_phone[mobile_phone_number]. A second host
          # adopting this engine must not have to remember that.
          assert_equal "[FILTERED]", filtered["phone"]
          assert_equal "[FILTERED]", filtered["mobile_phone_number"]
          # Decidim's own form posts mobile_phone[mobile_phone_number]; the
          # whole subtree is replaced, not just the leaf, so nothing inside it
          # can leak either.
          nested = ActiveSupport::ParameterFilter
                   .new(Rails.application.config.filter_parameters)
                   .filter("mobile_phone" => { "mobile_phone_number" => PHONE })
          assert_equal "[FILTERED]", nested["mobile_phone"]
          assert_equal "Dvorovi", filtered["komsiluk"], "ordinary parameters are still logged"
        end

        # The request log and the SQL log filter from two different lists, and
        # Rails does not keep them in step. A second host adopting this engine
        # must not have to discover that the hard way: a phone column that is
        # filtered out of the request log and printed in full at debug level
        # is a leak that only shows up while someone is troubleshooting an
        # incident.
        test "a generated host filters the phone attribute out of model inspection too" do
          contact = Decidim::Bih::Viber::BusinessContact.new(
            organization: @organization, user: @citizen, phone: PHONE, verified_at: Time.current
          )

          refute_empty Decidim::Bih::Viber::BusinessContact.filter_attributes,
                       "the engine, not the host, is what puts :phone on ActiveRecord::Base"
          refute_includes contact.inspect, PHONE
          assert_includes contact.inspect, "[FILTERED]"
        end

        # The engine owns the list, not the host: the behaviour above must
        # come from Decidim::Bih::Engine's own initializer. Rails precompiles
        # config.filter_parameters into one Regexp before any test can look at
        # it (config.precompile_filter_parameters), so assert on what the
        # engine's symbols compiled into rather than on the symbols.
        test "the engine declares the phone parameters it wants filtered" do
          # Rails precompiles config.filter_parameters into one Regexp before
          # any test can look at the list, so assert on the engine's own
          # declaration: the initializer that a second host adopting this
          # engine inherits.
          source = File.read(Decidim::Bih::Engine.root.join("lib/decidim/bih/engine.rb"))
          declared = source[/filter_parameters \+= \[(.*?)\]/m, 1]

          refute_nil declared, "the engine must still declare its own filtered parameters"
          %w(:entry_code :verification_code :otp_code :phone :mobile_phone).each do |symbol|
            assert_includes declared, symbol
          end

          assert_includes source, "ActiveRecord::Base.filter_attributes |=",
                          "and must re-sync them into the SQL-log list the host does not know about"
        end

        private

        def query_param(location, name)
          Rack::Utils.parse_query(URI.parse(location).query)[name]
        end
      end
    end
  end
end
