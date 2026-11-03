# frozen_string_literal: true

module Decidim
  module Bih
    module PhoneVerification
      # BIH verification links AND their codes have the existing 24-hour policy
      # (LoginToken::VERIFY_TTL). Passwordless login still expires in 10 minutes.
      # Keep upstream locking, validation, failed-attempt counters and grant
      # behavior; specialize only expiry for this BIH phone-completion path.
      # Native Decidim and other authorization workflows keep upstream expiry.
      class ConfirmAuthorization < Decidim::Verifications::ConfirmUserAuthorization
        private

        def code_expired?
          return super unless authorization.name == "sms"

          sent_at = authorization.verification_metadata["code_sent_at"]
          return false unless sent_at

          sent_at = Time.zone.parse(sent_at.to_s) if sent_at.is_a?(String)
          sent_at < Decidim::Bih::LoginToken::VERIFY_TTL.ago
        end
      end
    end
  end
end
