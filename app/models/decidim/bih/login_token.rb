# frozen_string_literal: true

module Decidim
  module Bih
    # Single-use, short-lived magic-link token. The raw token travels only
    # inside the SMS/Viber message; the database keeps a SHA-256 digest.
    class LoginToken < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_login_tokens"

      # Phone authentication is an active possession check. Both the link and
      # the code derived from its raw secret expire together after ten minutes.
      TTL = 10.minutes
      LOGIN_TTL = TTL

      # Verification links (and the SMS code that travels with them) are valid
      # for 24 hours — owner decision 2026-09-10, after an operator re-send
      # reached citizens who were not holding the phone and seven of eleven
      # links died unread at the old 10 minutes. The link still only proves
      # this one number, and a fresh send still invalidates the previous
      # token. The passwordless LOGIN link keeps its 10 minutes.
      VERIFY_TTL = 24.hours

      def self.ttl_for(purpose)
        case purpose.to_s
        when "postal" then POSTAL_TTL
        when "verify" then VERIFY_TTL
        when "login" then LOGIN_TTL
        when "invitation" then INVITATION_TTL
        else TTL
        end
      end

      # "verify"  — phone-verification + sign-in link delivered via SMS and Viber.
      #             Carries the phone the token was issued for so either channel
      #             (browser tap or Viber inbound) can recover it on consume.
      # "login"   — passwordless sign-in for already-verified users.
      # "postal"  — QR/magic-link mailed in the postal verification letter.
      #             Proof is physical receipt of the letter (no phone column set).
      #             Consuming it grants the pending postal_letter authorization.
      # "viber_verify" is retired: it was used when tokens were page-displayed
      #             (the old, unsound flow). Removed from PURPOSES so no new
      #             tokens of that purpose can be minted; existing unconsumed rows
      #             (if any) are harmless — they expire within their TTL and
      #             are never consumed by the corrected flows.
      # "invitation" — the confirm-attendance link in the launch invitation
      #             message. It NEVER signs anyone in (MagicLinksController
      #             branches on the purpose before any authentication path) and
      #             is deliberately not single-use: tapping it twice just shows
      #             "already confirmed". Dies with its 72h TTL.
      PURPOSES = %w(verify login postal invitation).freeze

      # Postal tokens are valid longer than SMS/login tokens so the letter has
      # time to be physically delivered and the recipient to act on it.
      POSTAL_TTL = 30.days
      INVITATION_TTL = 72.hours

      belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id
      belongs_to :organization, class_name: "Decidim::Organization",
                                foreign_key: :decidim_organization_id

      validates :purpose, inclusion: { in: PURPOSES }

      # +phone+ (DB column) is set for "verify" tokens so that either channel
      # (browser tap or Viber inbound) knows which phone the token proves control
      # of without round-tripping through sms authorization unique_id resolution.
      # Nil for "login" tokens and tokens issued before this column existed.

      def self.issue!(user:, purpose:, phone: nil)
        raw = SecureRandom.urlsafe_base64(24)
        ttl = ttl_for(purpose)
        transaction do
          # Serialize issue for this user before invalidating the prior token.
          # Without the row lock, two concurrent requests can both invalidate
          # the old row and each create a live token for the same purpose.
          user.lock!
          # rubocop:disable Rails/SkipsModelValidations
          where(user:, purpose:, consumed_at: nil).update_all(consumed_at: Time.current)
          create!(
            user:,
            organization: user.organization,
            purpose:,
            token_digest: digest(raw),
            expires_at: ttl.from_now,
            phone: phone
          )
          # rubocop:enable Rails/SkipsModelValidations
        end
        raw
      end

      # Atomically consumes the token: returns the record exactly once.
      def self.consume!(raw:, organization:, purpose: nil)
        token = peek(raw:, organization:, purpose:)
        return unless token

        claim!(token)
      end

      # Claims a record already checked by a proof path. Keeping the expiry in
      # the atomic UPDATE closes the boundary where a token expires after peek
      # but before its one-use claim. Callers may wrap this in a transaction;
      # a later failed grant can then roll the claim back before any sign-in.
      def self.claim!(token)
        # rubocop:disable Rails/SkipsModelValidations
        updated = where(id: token.id, consumed_at: nil)
                  .where(expires_at: Time.current..)
                  .update_all(consumed_at: Time.current)
        # rubocop:enable Rails/SkipsModelValidations
        token if updated == 1
      end

      # Finds a live token without consuming it (GET landing page).
      def self.peek(raw:, organization:, purpose: nil)
        return if raw.blank?

        scope = where(decidim_organization_id: organization.id, consumed_at: nil)
                .where(expires_at: Time.current..)
        scope = scope.where(purpose:) if purpose.present?
        scope.find_by(token_digest: digest(raw))
      end

      # Voids every still-live token of one purpose for one user in a single
      # UPDATE. Used wherever a credential has done its job (the phone is
      # proven) or is being thrown away (the citizen changes number): both SMS
      # and Viber carry a link, so leaving the other one live would leave a
      # usable credential behind.
      def self.invalidate_live!(user:, purpose:)
        # rubocop:disable Rails/SkipsModelValidations
        where(user:, purpose:, consumed_at: nil).update_all(consumed_at: Time.current)
        # rubocop:enable Rails/SkipsModelValidations
      end

      def self.digest(raw) = Digest::SHA256.hexdigest(raw)
    end
  end
end
