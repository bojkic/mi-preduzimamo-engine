# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # Handles a "verify_<token>" message arriving over the Viber inbound
      # webhook (corrected, sound model — Round 14).
      #
      # SOUNDNESS ARGUMENT
      # ==================
      # Phone verification works by POSSESSION OF A ONE-TIME SECRET DELIVERED
      # to a specific phone number. Viber Business Messages (via Infobip) are
      # addressed by phone number — Infobip routes a Viber business message to
      # the Viber account registered on that SIM, exactly as SMS is routed.
      # Therefore:
      #
      #   Sending the one-time link to phone X over Viber and having it
      #   activated proves control of X to the SAME standard as SMS.
      #
      # The previous (incorrect) design displayed the token ON the web page
      # and waited for the user to relay it from their Viber — that never
      # addressed a known phone, so it could not prove the phone.
      #
      # The corrected flow:
      #   1. InfobipGateway mints ONE "verify" token and delivers it to phone X
      #      over BOTH SMS and Viber.  The token records the phone.
      #   2. The user taps the link in either channel (first activation wins —
      #      single-use).
      #   3a. Browser tap  → MagicLinksController#consume (grants + signs in).
      #   3b. Viber inbound → THIS class (grants + records linkage).
      #
      # Both paths call the same GrantsSmsAuthorization shared concern, so the
      # grant mechanism is identical regardless of channel.
      #
      # What this flow does on a valid consumed token:
      #   1. Grants the token-user's pending sms authorization via the canonical
      #      Decidim::Verifications::ConfirmUserAuthorization command.
      #   2. Creates or updates the Viber::Linkage with the sender,
      #      decidim_user_id, and the real phone X (recovered from the token's
      #      +phone+ column — stored at issue time by InfobipGateway).
      #   3. Returns a localized welcome reply.
      #
      # On an expected invalid/expired/cross-org token this returns nil so the
      # normal intent chain can respond. Database/grant failures roll back token
      # consumption and linkage atomically; durable receipt callers request
      # strict propagation so recovery can retry rather than lose the proof.
      class ViberVerifyFlow
        include Decidim::Bih::GrantsSmsAuthorization

        # The "verify_" prefix identifies the normalized verification primitive
        # on the Viber webhook path. Infobip sends it in an official Viber Bots
        # CONVERSATION_STARTED `message.context`; InboundMessage admits only this
        # narrowly-shaped context and maps it to a sender-bound TEXT primitive.
        #
        # The plain magic-link URL (also delivered in the same Viber message as
        # a clickable hyperlink, short /v/:token or mounted depending on host
        # config) routes via the BROWSER path (MagicLinksController#consume) -
        # not here. If a user somehow sends the full URL as a text message it
        # will NOT match TOKEN_PREFIX and falls through to the normal intent
        # chain (graceful: no grant, no error).
        TOKEN_PREFIX = "verify_"
        TOKEN_PATTERN = /\Averify_[A-Za-z0-9_-]{20,128}\z/

        def initialize(organization:)
          @organization = organization
        end

        # Returns a Reply on a consumed valid "verify" token, nil otherwise.
        # The inner transaction becomes a savepoint when the durable receipt
        # already owns a transaction, and a top-level transaction for direct
        # callers. Either way a failed grant never burns the one-time token.
        def call(message, strict: false)
          return nil unless verify_context?(message)

          raw_token = extract_token(message.text)
          return nil if raw_token.blank?

          ActiveRecord::Base.transaction(requires_new: true) do
            consume_and_link!(raw_token, message)
          end
        rescue StandardError => e
          Rails.logger.error(
            "[ViberVerifyFlow] #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}"
          )
          raise if strict

          nil
        end

        private

        attr_reader :organization

        # LOCK ORDER: user, then token. Everything else in the app takes locks
        # that way — LoginToken.issue! locks the user row before it invalidates
        # that user's live tokens, and Complete locks the user before it voids
        # them. Consuming first would take the token row lock inside THIS
        # transaction and only then ask Complete for the user lock, so an
        # inbound webhook and a concurrent issue! could hold one lock each and
        # wait for the other. Peeking is lock-free, so peek → lock the user →
        # consume keeps this path on the same order as the rest.
        def consume_and_link!(raw_token, message)
          # Org-scoped peek. Accepts "verify" tokens only; "viber_verify"
          # tokens are retired and will not be found here.
          token_record = Decidim::Bih::LoginToken.peek(
            raw: raw_token, organization: organization, purpose: "verify"
          )
          return nil if token_record.nil? # expired, already consumed, or cross-org

          user = token_record.user
          sender = message.respond_to?(:sender) ? message.sender : nil
          return nil if sender.blank?

          # A blocked or deleted user must NEITHER receive a grant NOR get a
          # linkage written. grant_sms_authorization already refuses on the
          # active predicate; gate the linkage write on the SAME predicate so a
          # blocked/deleted account never keeps a linkage that confers points or
          # report authorship via Viber.
          return nil unless active_grantable_user?(user)

          # Take the user lock BEFORE burning the token (see LOCK ORDER above).
          # lock! RELOADS the row, so the predicate above was decided on a
          # possibly stale read — an admin could have blocked this account in
          # between. Re-assert it on the locked row, which is the one the
          # linkage write and the grant will actually be based on.
          user.lock!
          return nil unless active_grantable_user?(user)

          # Single-use consume, now under the user lock. A nil here means
          # another channel (the browser tap) consumed the same token between
          # the peek and this statement — the grant is that channel's job.
          token_record = Decidim::Bih::LoginToken.consume!(
            raw: raw_token, organization: organization, purpose: "verify"
          )
          return nil if token_record.nil?

          # Grant the pending sms authorization — this is sound because the
          # token was DELIVERED to the phone (never page-displayed). Pass the
          # phone from the token so the concern can enforce the phone-binding
          # invariant (authorization unique_id must match this exact phone).
          granted = grant_sms_authorization(
            user,
            nil,
            expected_phone: token_record.phone,
            raise_on_failure: true
          )
          raise "Viber verification authorization grant failed" unless granted

          # Create or update the Linkage with the phone from the token. The token
          # stores the phone exactly as Decidim sanitized it (may keep a leading
          # "+"); create_or_update_linkage normalizes it to the digits-only form
          # the OTP path uses before persisting.
          create_or_update_linkage(sender: sender, user: user, phone: token_record.phone)

          Decidim::Bih::Concierge::Responder::Reply.new(
            text: I18n.t("decidim.bih.goodwill.verify_cta.viber.welcome", locale: "sr"),
            report: nil,
            answer_intent: "account_linking"
          )
        end

        # True when the message text starts with "verify_" — the prefix that
        # identifies an inbound verification message. Non-verify messages pass
        # through to the normal intent chain.
        def verify_context?(message)
          message.text.to_s.match?(TOKEN_PATTERN)
        end

        # Strips "verify_" prefix; the remainder is the raw token.
        def extract_token(text)
          text.to_s.delete_prefix(TOKEN_PREFIX).strip.presence
        end

        # Upserts the Linkage for (org, sender). Writes:
        #   - phone: the verified phone from the token (nil if the token was
        #            issued before the phone column existed — graceful degradation).
        #   - decidim_user_id: the token's user (sms-auth user).
        #   - verified_at: now.
        #
        # If a prior OTP-flow linkage exists for this sender with a real phone
        # already set, the new phone (same one, from the same token) overwrites
        # it only if it is non-nil. A nil phone (legacy token) never overwrites
        # a previously-verified real phone.
        def create_or_update_linkage(sender:, user:, phone:)
          linkage = Decidim::Bih::Viber::Linkage.find_or_initialize_by(
            organization: organization, viber_sender: sender
          )
          # Normalize to the digits-only form the OTP path stores (the token can
          # carry a "+"-prefixed phone from MobilePhoneForm). Only write a real
          # value — never overwrite a verified phone with nil.
          normalized = Decidim::Bih::Viber::Linkage.normalize_phone(phone)
          linkage.phone = normalized if normalized.present?
          linkage.verified_at = Time.current
          linkage.decidim_user_id = user.id
          linkage.save!
        end
      end
    end
  end
end
