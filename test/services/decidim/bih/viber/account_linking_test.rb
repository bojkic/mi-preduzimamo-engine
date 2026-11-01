# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/access"
require "active_support/security_utils"
require "openssl"
require "securerandom"
require "logger"
require_relative "../../../../../app/services/decidim/bih/log_redactor"

# AccountLinking inherits no AR base, but it references a handful of sibling
# Decidim::Bih constants. We provide just enough of them (only when absent) to
# load the file host-free, then exercise the OTP start/verify guard state machine
# through an injected fake OtpStore.
#
# The persisted side effects (#link! writing a Linkage row, #linked_user /
# #linked_phone reading one, the SMS-unique-id user resolution) all hit
# ActiveRecord and are integration-only. The test subclass below overrides the
# three host-coupled seams the guard logic does NOT depend on — #link! (AR
# write), #digest_for (Rails secret) and #otp_text (full I18n locale files) — so
# the constant-time digest comparison, attempt-burn, expiry and rate-limit guards
# can all be asserted without a Rails host or DB. The HMAC keyed digest is
# reproduced with a fixed test key so the real ActiveSupport::SecurityUtils
# secure_compare path stays exercised end to end.
module Decidim
  module Bih
    module Infobip
      const_set(:Error, Class.new(StandardError)) unless const_defined?(:Error, false)
      # Placeholder for the default gateway arg; tests always inject a FakeGateway,
      # so this is never instantiated. const_set keeps it a non-empty definition.
      const_set(:Client, Class.new) unless const_defined?(:Client, false)
    end

    module Viber
      unless const_defined?(:Linkage, false)
        class Linkage
          MIN = 8
          MAX = 15

          def self.normalize_phone(phone)
            digits = phone.to_s.gsub(/\D/, "")
            digits.length.between?(MIN, MAX) ? digits : nil
          end
        end
      end
    end
  end
end

require_relative "../../../../../app/services/decidim/bih/viber/otp_store"
require_relative "../../../../../app/services/decidim/bih/viber/account_linking"

# The :send_failed rescue path logs through Rails.logger + LogRedactor. Provide a
# null-logger Rails shim ONLY when Rails is genuinely absent (engine unit run);
# under the host/railties it is left untouched. Defined once at load and never
# removed, so it can never clobber a Rails another test relies on.
unless Object.const_defined?(:Rails)
  rails_shim = Module.new
  rails_shim.define_singleton_method(:logger) { @logger ||= Logger.new(File::NULL) }
  rails_shim.define_singleton_method(:env) { ActiveSupport::StringInquirer.new("test") }
  Object.const_set(:Rails, rails_shim)
end

module Decidim
  module Bih
    module Viber
      class AccountLinkingTest < Minitest::Test
        SECRET = "account-linking-test-secret"
        SENDER = "viber-sender-1"
        RAW_PHONE = "+387 65 123-456"
        NORMALIZED_PHONE = "38765123456"

        # In-memory stand-in for OtpStore honouring the exact contract
        # AccountLinking depends on. A test can pre-seed a pending OTP or constrain
        # the send budget, and inspect what was put/cleared and the attempt count.
        class FakeOtpStore
          attr_reader :put_calls, :cleared, :attempts, :seen_senders, :sender_rate_checks, :phone_rate_checks

          def initialize(allow_send: true, allow_send_to: true, pending: nil)
            @allow_send = allow_send
            @allow_send_to = allow_send_to
            @pending = pending
            @attempts = 0
            @put_calls = []
            @cleared = false
            @seen_senders = []
            @sender_rate_checks = []
            @phone_rate_checks = []
          end

          def for_organization(_org_id) = self

          def allow_send?(sender:)
            @seen_senders << sender
            @sender_rate_checks << sender
            @allow_send
          end

          def allow_send_to?(phone:)
            @to = phone
            @phone_rate_checks << phone
            @allow_send_to
          end

          def put(sender:, phone:, digest:, ttl: nil)
            @put_calls << { sender:, phone:, digest:, ttl: }
            @pending = { phone:, digest:, created_at: Time.now.to_i }
            @attempts = 0
          end

          def get(sender:)
            @seen_senders << sender
            @pending
          end

          def increment_attempts(sender:)
            @seen_senders << sender
            return nil if @pending.nil?

            @attempts += 1
          end

          def clear(sender:)
            @seen_senders << sender
            @cleared = true
            @pending = nil
          end
        end

        # Captures send_sms calls; can be told to raise the Infobip error to drive
        # the :send_failed branch. Reports configured? so the dev path is skipped.
        class FakeGateway
          attr_reader :sent

          def initialize(raise_error: false, configured: true)
            @raise_error = raise_error
            @configured = configured
            @sent = []
          end

          def configured? = @configured

          def send_sms(to:, text:)
            raise Decidim::Bih::Infobip::Error, "boom" if @raise_error

            @sent << { to:, text: }
          end
        end

        OrgStub = Struct.new(:id, keyword_init: true)

        # Host-decoupled subclass: overrides only the seams that touch the Rails
        # secret, the locale files and ActiveRecord. The keyed-HMAC recipe is the
        # same one production uses, with a fixed test key, so the real
        # secure_compare guard is still exercised.
        class HostFreeAccountLinking < AccountLinking
          TEST_HMAC_KEY = AccountLinkingTest::SECRET

          attr_reader :linked

          def link!(sender:, phone:)
            @linked = { sender:, phone: }
          end

          def digest_for(code)
            OpenSSL::HMAC.hexdigest("SHA256", TEST_HMAC_KEY, code.to_s)
          end

          def otp_text(code)
            "code:#{code}"
          end
        end

        def setup
          @org = OrgStub.new(id: 1)
        end

        # --- start: rate limiting & minting -------------------------------------

        def test_start_rejects_input_that_is_not_a_phone
          store = FakeOtpStore.new
          linking = build(store:)

          assert_equal :invalid_phone, linking.start(sender: SENDER, phone: "12")
          assert_empty store.put_calls, "no OTP may be minted for a non-phone"
        end

        def test_start_is_rate_limited_when_the_sender_cap_is_exhausted
          store = FakeOtpStore.new(allow_send: false)
          linking = build(store:)

          assert_equal :rate_limited, linking.start(sender: SENDER, phone: RAW_PHONE)
          assert_empty store.put_calls, "rate-limited start must not store an OTP"
        end

        def test_start_is_rate_limited_when_the_destination_cap_is_exhausted
          store = FakeOtpStore.new(allow_send_to: false)
          linking = build(store:)

          assert_equal :rate_limited, linking.start(sender: SENDER, phone: RAW_PHONE)
          assert_empty store.put_calls
        end

        def test_start_stores_only_a_digest_and_sends_the_sms_on_success
          store = FakeOtpStore.new
          gateway = FakeGateway.new
          linking = build(store:, gateway:)

          assert_equal :otp_sent, linking.start(sender: SENDER, phone: RAW_PHONE)

          call = store.put_calls.fetch(0)
          assert_equal NORMALIZED_PHONE, call[:phone], "the stored phone is digit-normalized"
          assert_equal 64, call[:digest].length, "an HMAC-SHA256 hex digest is stored"
          assert_match(/\A[0-9a-f]{64}\z/, call[:digest])
          assert_nil call[:digest][/\b\d{6}\b/], "the plaintext 6-digit code is never stored"
          assert_equal 1, gateway.sent.length
          assert_equal NORMALIZED_PHONE, gateway.sent.fetch(0)[:to]
        end

        def test_start_reports_send_failed_when_the_gateway_raises
          store = FakeOtpStore.new
          gateway = FakeGateway.new(raise_error: true)
          linking = build(store:, gateway:)

          # The :send_failed rescue logs via Rails.logger; guarantee a usable
          # logger whether Rails is the railties module (logger nil until an app
          # boots) or the engine-unit null-logger shim.
          with_rails_logger do
            assert_equal :send_failed, linking.start(sender: SENDER, phone: RAW_PHONE)
          end
        end

        def test_production_unconfigured_start_fails_before_rate_or_otp_mutation
          store = FakeOtpStore.new
          gateway = FakeGateway.new(configured: false)
          linking = build(store:, gateway:)

          with_environment("production") do
            assert_equal :unconfigured, linking.start(sender: SENDER, phone: RAW_PHONE)
          end
          assert_empty store.sender_rate_checks
          assert_empty store.phone_rate_checks
          assert_empty store.put_calls
          assert_empty gateway.sent
        end

        def test_nonproduction_unconfigured_start_keeps_offline_flow_available
          store = FakeOtpStore.new
          gateway = FakeGateway.new(configured: false)
          linking = build(store:, gateway:)

          assert_equal :unconfigured, linking.start(sender: SENDER, phone: RAW_PHONE)
          assert_equal [SENDER], store.sender_rate_checks
          assert_equal [NORMALIZED_PHONE], store.phone_rate_checks
          assert_equal 1, store.put_calls.size
          assert_empty gateway.sent
        end

        # --- verify: state machine ----------------------------------------------

        def test_verify_returns_no_pending_when_there_is_nothing_to_check
          linking = build(store: FakeOtpStore.new(pending: nil))

          assert_equal :no_pending, linking.verify(sender: SENDER, code: "123456")
        end

        def test_verify_rejects_and_burns_an_expired_otp
          store = FakeOtpStore.new(
            pending: { phone: NORMALIZED_PHONE, digest: "deadbeef",
                       created_at: Time.now.to_i - OtpStore::DEFAULT_TTL - 5 }
          )
          linking = build(store:)

          assert_equal :expired, linking.verify(sender: SENDER, code: "123456")
          assert store.cleared, "an expired OTP must be cleared"
        end

        def test_verify_accepts_the_correct_code_and_links
          code = "246810"
          store = FakeOtpStore.new(pending: pending_for(code))
          linking = build(store:)

          assert_equal :verified, linking.verify(sender: SENDER, code:)
          assert store.cleared, "a verified OTP must be cleared"
          assert_equal NORMALIZED_PHONE, linking.linked[:phone]
        end

        def test_verify_rejects_a_wrong_code_and_counts_the_attempt
          store = FakeOtpStore.new(pending: pending_for("246810"))
          linking = build(store:)

          assert_equal :invalid, linking.verify(sender: SENDER, code: "000000")
          assert_equal 1, store.attempts, "a wrong guess must be counted"
          assert_equal false, store.cleared, "below the attempt limit the OTP must survive for retry"
        end

        def test_verify_burns_the_otp_once_the_attempt_limit_is_reached
          store = FakeOtpStore.new(pending: pending_for("246810"))
          # Pre-inflate so this wrong guess is the MAX_ATTEMPTS-th.
          (AccountLinking::MAX_ATTEMPTS - 1).times { store.increment_attempts(sender: SENDER) }
          linking = build(store:)

          assert_equal :invalid, linking.verify(sender: SENDER, code: "999999")
          assert store.cleared, "reaching the attempt limit must burn the pending OTP"
        end

        def test_verify_compares_digests_not_raw_codes_and_rejects_a_near_miss
          # The stored digest is the HMAC of the real code; a one-digit-different
          # code of the same length must still be rejected, proving the guard
          # compares keyed digests (constant-time) rather than the raw input.
          store = FakeOtpStore.new(pending: pending_for("135790"))
          linking = build(store:)

          assert_equal :invalid, linking.verify(sender: SENDER, code: "135791")
        end

        def test_verify_rejects_when_the_stored_digest_is_missing
          # A tampered/garbled Redis entry with no digest must never authenticate.
          store = FakeOtpStore.new(
            pending: { phone: NORMALIZED_PHONE, digest: "", created_at: Time.now.to_i }
          )
          linking = build(store:)

          assert_equal :invalid, linking.verify(sender: SENDER, code: "135790")
        end

        private

        def build(store:, gateway: FakeGateway.new)
          HostFreeAccountLinking.new(organization: @org, gateway:, otp_store: store)
        end

        # The HMAC digest HostFreeAccountLinking computes for +code+, so a
        # pre-seeded pending OTP matches a verify call for the same code.
        def pending_for(code)
          digest = OpenSSL::HMAC.hexdigest("SHA256", SECRET, code)
          { phone: NORMALIZED_PHONE, digest:, created_at: Time.now.to_i }
        end

        # Ensures Rails.logger returns a real logger for the block. Under the full
        # suite Rails is the railties module with a nil logger; under the engine
        # unit run it is the null-logger shim. Either way we stub a null logger and
        # restore the original afterwards, never mutating shared state past here.
        def with_rails_logger
          null_logger = Logger.new(File::NULL)
          Rails.stub(:logger, null_logger) { yield }
        end

        def with_environment(name)
          Rails.stub(:env, ActiveSupport::StringInquirer.new(name)) { yield }
        end
      end
    end
  end
end
