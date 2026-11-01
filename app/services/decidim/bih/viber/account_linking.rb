# frozen_string_literal: true

require "openssl"
require "securerandom"

module Decidim
  module Bih
    module Viber
      # Verifies that a Viber sender controls a phone number, via a one-time
      # passcode (OTP) delivered out-of-band over SMS.
      #
      # THREAT MODEL / WHAT THIS IS NOT:
      #   Proving control of a phone authorises exactly ONE thing — attributing
      #   that Viber sender's civic reports to the phone (reporter_phone). It does
      #   NOT authenticate, create, or mutate any Decidim::User, and it never
      #   starts a Decidim session. A citizen who happens to share a phone with an
      #   existing account gains no access to that account. The only record kept
      #   is a Decidim::Bih::Viber::Linkage row ("sender S controls phone P").
      #
      # OTP HARDENING (all enforced here + in OtpStore):
      #   * 6-digit numeric code, generated with SecureRandom.
      #   * Only an HMAC-SHA256 DIGEST is stored (keyed by the app secret); the
      #     plaintext lives solely in the SMS we send out.
      #   * Codes EXPIRE (OtpStore TTL, ~10 min).
      #   * ATTEMPT LIMIT (MAX_ATTEMPTS): after too many wrong guesses the pending
      #     OTP is invalidated, forcing a fresh send.
      #   * Verification uses ActiveSupport::SecurityUtils.secure_compare on the
      #     digests (constant-time) to avoid timing oracles.
      #   * SEND RATE LIMITS cap OTP sends per SENDER and per DESTINATION PHONE
      #     (the latter is what actually stops SMS-bombing a victim's number,
      #     since the sender id is attacker-controlled).
      class AccountLinking
        # Wrong guesses tolerated before the pending OTP is burned.
        MAX_ATTEMPTS = 5

        # Plausible MSISDN length once stripped to digits (e.g. 3876XXXXXXX, or a
        # local 06XXXXXXX). Anything outside this band is rejected as not a phone.
        MIN_PHONE_DIGITS = 8
        MAX_PHONE_DIGITS = 15

        # +organization+ scopes both the Redis keys and the Linkage row.
        # +gateway+ delivers the SMS; it may be a Decidim::Bih::Infobip::Client
        # (responds to #send_sms/#configured?) or any callable taking
        # (phone, text). +otp_store+ is injectable for tests.
        def initialize(organization:, gateway: Decidim::Bih::Infobip::Client.new, otp_store: OtpStore.new)
          @organization = organization
          @gateway = gateway
          @store = otp_store.for_organization(organization.id)
        end

        # Begins (or restarts) verification for +sender+ against +phone+.
        # Returns one of:
        #   :invalid_phone — the input doesn't look like a phone number
        #   :rate_limited  — too many sends in the window; nothing sent
        #   :otp_sent      — code generated, digest stored, SMS dispatched
        #   :send_failed   — gateway raised on a real send (caller should report it)
        #   :unconfigured  — gateway can't deliver. Production returns this
        #                    before rate/OTP mutation; non-production still stores
        #                    and logs the code so the flow stays testable end-to-end
        def start(sender:, phone:)
          normalized = normalize_phone(phone)
          return :invalid_phone if normalized.nil?
          return :unconfigured if production_environment? && !delivery_available?

          # Limit by BOTH the sender and the destination phone — the destination
          # cap is what actually protects a victim's number from SMS-bombing,
          # since the sender id is attacker-controlled. (Evaluate both so each
          # counter records the attempt.)
          sender_ok = @store.allow_send?(sender: sender)
          phone_ok = @store.allow_send_to?(phone: normalized)
          return :rate_limited unless sender_ok && phone_ok

          code = generate_code
          @store.put(sender: sender, phone: normalized, digest: digest_for(code))

          deliver(phone: normalized, code: code)
        end

        # Checks +code+ against the pending OTP for +sender+. Returns:
        #   :no_pending — nothing to verify (never started / already cleared)
        #   :expired    — the OTP TTL lapsed (treated same as no pending state)
        #   :invalid    — wrong code; attempt counted (OTP burned at the limit)
        #   :verified   — correct code; Linkage upserted, OTP cleared
        def verify(sender:, code:)
          pending = @store.get(sender: sender)
          return :no_pending if pending.nil?

          # Belt-and-suspenders expiry: Redis TTL normally evicts a stale OTP, but
          # we also reject one whose stored age exceeds the lifetime, so a clock
          # skew or a TTL-less write can never extend a code's validity.
          if expired?(pending)
            @store.clear(sender: sender)
            return :expired
          end

          unless correct_code?(pending, code)
            attempts = @store.increment_attempts(sender: sender)
            @store.clear(sender: sender) if attempts && attempts >= MAX_ATTEMPTS
            return :invalid
          end

          link!(sender: sender, phone: pending[:phone])
          @store.clear(sender: sender)
          :verified
        end

        # The verified phone for +sender+, or nil when not linked. Used by the
        # concierge to attribute reports.
        def linked_phone(sender:)
          Decidim::Bih::Viber::Linkage
            .where(organization: @organization, viber_sender: sender)
            .where.not(verified_at: nil)
            .pick(:phone)
        end

        # The resolved Decidim::User for +sender+ (from decidim_user_id stored at
        # verify time), or nil when the sender has no linkage or the linkage has
        # no associated user. Used by the concierge goodwill_user_resolver.
        def linked_user(sender:)
          linkage = Decidim::Bih::Viber::Linkage
                    .where(organization: @organization, viber_sender: sender)
                    .where.not(verified_at: nil)
                    .first
          return nil unless linkage&.decidim_user_id

          user = Decidim::User.find_by(id: linkage.decidim_user_id, organization: @organization)
          # A pre-existing linkage may point at an account that was blocked or
          # deleted AFTER linking. Such an account must stop conferring points or
          # report authorship, so reject any non-active user here.
          return nil unless active_user?(user)
          return nil unless resolve_decidim_user_id(linkage.phone) == user.id

          user
        end

        # The active Decidim::User whose granted sms authorization matches
        # +phone+, or nil. Public because Viber Business Messages is
        # MSISDN-addressed: the carrier hands us a proven phone directly, so
        # BusinessMessageIdentity can resolve the citizen without ever running
        # the OTP flow this class exists for.
        def user_for_phone(phone)
          user_id = resolve_decidim_user_id(Decidim::Bih::Viber::Linkage.normalize_phone(phone))
          return nil unless user_id

          user = Decidim::User.find_by(id: user_id, organization: @organization)
          return nil unless active_user?(user)

          user
        end

        private

        attr_reader :organization, :gateway

        # True only when the user exists and is active, not blocked, not deleted —
        # the same predicate the grant path (GrantsSmsAuthorization) enforces.
        def active_user?(user)
          user&.active_for_authentication? && !user.blocked? && !user.deleted?
        end

        # True when the pending OTP is older than the store's TTL.
        def expired?(pending)
          created_at = pending[:created_at]
          return false if created_at.nil?

          (Time.now.to_i - created_at.to_i) > OtpStore::DEFAULT_TTL
        end

        # Constant-time digest comparison. The stored digest may be missing/garbled
        # if Redis was tampered with; guard so a nil never reaches secure_compare.
        def correct_code?(pending, code)
          stored = pending[:digest].to_s
          return false if stored.empty?

          ActiveSupport::SecurityUtils.secure_compare(stored, digest_for(code.to_s))
        end

        # Idempotently records "sender controls phone". Re-verifying updates the
        # same (org, sender) row rather than creating account-like duplicates.
        #
        # PHONE-TO-USER RESOLUTION (Round 10): we attempt to find the
        # Decidim::User in this org whose sms authorization unique_id matches the
        # phone. The unique_id recipe (from MobilePhoneForm) is:
        #   SHA-256 of "#{sanitized_phone}-#{Rails.application.secret_key_base}"
        # where sanitized_phone has non-[+0-9] stripped.
        #
        # AMBIGUITY: the stored phone is digits-only (e.g. "3876XXXXXXX") but the
        # user may have typed a "+"-prefixed number ("+3876XXXXXXX") at
        # verification time. We compute both candidates:
        #   candidate_a: "3876XXXXXXX"  (digits-only — as stored)
        #   candidate_b: "+3876XXXXXXX" (with leading +)
        # If exactly one user is found across both candidates we store their id.
        # Zero matches (user not yet verified, or verified with a different phone
        # format we cannot reconstruct) or multiple matches (colliding hashes,
        # practically impossible) → decidim_user_id stays nil; behavior is
        # unchanged (phone-only linkage).
        def link!(sender:, phone:)
          linkage = Decidim::Bih::Viber::Linkage.find_or_initialize_by(
            organization: organization, viber_sender: sender
          )
          linkage.phone = phone
          linkage.verified_at = Time.current
          linkage.decidim_user_id = resolve_decidim_user_id(phone)
          linkage.save!
        end

        # Resolves a Decidim::User by matching the phone against sms authorization
        # unique_ids. Returns the user id when exactly one match is found, else nil.
        #
        # CANDIDATES: we try four normalizations because Decidim's MobilePhoneForm
        # only strips non-[+0-9] characters — users may have verified with any of:
        #   a) digits-only e.g. "3876XXXXXXX"    (as stored by OTP flow)
        #   b) +-prefixed   e.g. "+3876XXXXXXX"
        #   c) local 0-prefix e.g. "06XXXXXXX"   (user typed local format at verify time)
        #   d) local bare  e.g. "6XXXXXXX"        (rare but possible with some keyboards)
        #
        # The BiH country code is 387. We strip a leading "387" and prepend "0" to
        # produce candidate (c), which is the most common local format in the region.
        # Candidate (d) omits the leading zero (bare national). This is best-effort:
        # canonical E.164 normalization on both sides (at verify time and here) is the
        # durable fix — deferred because it would require a unique_id data migration.
        def resolve_decidim_user_id(phone)
          digits = phone.to_s

          candidate_a = digits # digits-only (as stored by OTP flow)
          candidate_b = "+#{digits}" # +-prefixed variant

          # Local BiH format: strip leading country code "387" → prepend "0"
          # e.g. "3876XXXXXXX" → "06XXXXXXX"
          candidate_c = ("0#{digits.delete_prefix("387")}" if digits.start_with?("387"))

          # Bare national (no leading zero): e.g. "6XXXXXXX" (less common)
          candidate_d = (candidate_c.delete_prefix("0") if candidate_c)

          digests = [candidate_a, candidate_b, candidate_c, candidate_d]
                    .compact
                    .map { |c| sms_unique_id(c) }
                    .uniq

          # Find granted sms authorizations whose unique_id matches either
          # digest, scoped to this organization.
          auth_scope = Decidim::Authorization
                       .where(name: "sms")
                       .where.not(granted_at: nil)
                       .where(unique_id: digests)
                       .joins(:user)
                       .merge(Decidim::User.where(organization: organization))

          # Load the unique user ids the authorizations point to.
          user_ids = auth_scope.pluck(:decidim_user_id).uniq
          return nil unless user_ids.size == 1

          user_ids.first
        rescue StandardError => e
          # Never let a failed user-lookup break the OTP verify flow.
          Rails.logger.warn(
            "[AccountLinking] user resolution failed for " \
            "#{Decidim::Bih::LogRedactor.mask_phone(phone)}: #{e.class}: #{e.message}"
          )
          nil
        end

        # Computes the same SHA-256 unique_id that MobilePhoneForm uses.
        # MobilePhoneForm#mobile_phone_number strips everything except [+0-9],
        # then unique_id = SHA-256("#{number}-#{secret_key_base}"). unique_id_for
        # performs that exact normalization + hashing for each candidate.
        def sms_unique_id(phone_candidate)
          Decidim::Bih::SmsAuthorization.unique_id_for(phone_candidate)
        end

        # Dispatches the OTP SMS, degrading to a logged dev path when the gateway
        # is unconfigured (so the whole flow is exercisable without Infobip creds).
        def deliver(phone:, code:)
          text = otp_text(code)

          unless delivery_available?
            # Dev convenience only — NEVER log a live OTP + phone in production.
            unless production_environment?
              Rails.logger&.info(
                "[AccountLinking] Infobip unconfigured; OTP for " \
                "#{Decidim::Bih::LogRedactor.mask_phone(phone)} is #{code}"
              )
            end
            return :unconfigured
          end

          send_via_gateway(phone:, text:, code:)
          :otp_sent
        rescue Decidim::Bih::Infobip::Error => e
          # A delivery failure must not leak as a 500 into the webhook. Return a
          # DISTINCT result so the caller tells the user it failed (rather than
          # advancing to "enter the code" for a code that was never sent).
          Rails.logger&.error(
            "[AccountLinking] OTP send failed for #{Decidim::Bih::LogRedactor.mask_phone(phone)}: " \
            "#{Decidim::Bih::LogRedactor.error_message(e)}"
          )
          :send_failed
        end

        # A callable test/development gateway without #configured? remains
        # available. Real provider gateways report their complete delivery
        # capability, including the mandatory final SMS channel.
        def delivery_available?
          return true unless gateway.respond_to?(:configured?)

          gateway.configured? == true
        rescue StandardError
          false
        end

        def production_environment?
          Rails.respond_to?(:env) && Rails.env.production?
        end

        # Supports both an Infobip-style client (#send_sms) and a plain callable.
        def send_via_gateway(phone:, text:, code:)
          if gateway.respond_to?(:send_sms)
            if gateway_accepts_template?
              gateway.send_sms(to: phone, text: text, viber_template: viber_otp_template(code))
            else
              gateway.send_sms(to: phone, text: text)
            end
          else
            gateway.call(phone, text)
          end
        end

        def gateway_accepts_template?
          gateway.method(:send_sms).parameters.any? do |type, name|
            type == :keyrest || ([:key, :keyreq].include?(type) && name == :viber_template)
          end
        end

        def viber_otp_template(code)
          config = Decidim::Bih::Config.infobip
          return if config[:viber_otp_template_id].blank?

          {
            template_id: config[:viber_otp_template_id],
            language: config[:viber_template_language],
            parameters: { pin: code }
          }
        end

        def otp_text(code)
          I18n.t("decidim.bih.concierge.link.sms", code: code, locale: "sr")
        end

        # Cryptographically random 6-digit code, zero-padded (000000–999999).
        def generate_code
          format("%06d", SecureRandom.random_number(1_000_000))
        end

        # Keyed HMAC over the code so a leaked Redis snapshot can't be brute-forced
        # offline without the app secret (6 digits is a tiny space for a bare hash).
        def digest_for(code)
          OpenSSL::HMAC.hexdigest("SHA256", hmac_key, code.to_s)
        end

        def hmac_key
          Rails.application.secret_key_base
        end

        # Delegates to Linkage.normalize_phone so both the OTP flow and the
        # Viber-notification lookup always use identical digit stripping.
        def normalize_phone(phone)
          Decidim::Bih::Viber::Linkage.normalize_phone(phone)
        end
      end
    end
  end
end
