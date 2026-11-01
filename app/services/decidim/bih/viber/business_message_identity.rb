# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # Identity adapter for the Viber Business Messages concierge channel.
      #
      # It presents the same interface the responder expects from
      # Decidim::Bih::Viber::AccountLinking, but exploits the one way Business
      # Messages differs from the Viber Bot: BM is **MSISDN-addressed**. The
      # sender Infobip hands us IS the citizen's phone number, proven by the
      # carrier. The Bot, by contrast, gives an opaque bot user id, which is why
      # it needed an OTP round-trip to learn the phone at all.
      #
      # So on this channel:
      #   * #linked_phone returns the sender itself — attribution with no OTP.
      #   * #linked_user resolves through the citizen's granted sms
      #     authorization, falling back to a Bot-era Linkage row if one exists.
      #   * #start / #verify still delegate to AccountLinking, so the explicit
      #     "poveži me" keyword flow keeps working exactly as before for anyone
      #     who wants to bind a *different* number than the one they message from.
      class BusinessMessageIdentity
        def initialize(organization:, account_linking:)
          @organization = organization
          @account_linking = account_linking
        end

        # The sender's own MSISDN. Business Messages cannot be addressed by
        # anything else, so a present sender is always a usable phone.
        def linked_phone(sender:)
          normalized = Decidim::Bih::Viber::Linkage.normalize_phone(sender) if sender.to_s.match?(/\A\+?[0-9]{8,15}\z/)
          return normalized if normalized.present?

          # A sender that does not normalize to a plausible MSISDN is not a
          # Business Messages sender; fall back rather than attributing wrongly.
          account_linking.linked_phone(sender:)
        end

        # Prefer an explicit Bot-era linkage (a citizen who deliberately bound a
        # different number keeps that binding), then fall back to resolving the
        # sender's own number through its granted sms authorization.
        def linked_user(sender:)
          linked = account_linking.linked_user(sender:)
          return linked if linked
          return unless sender.to_s.match?(/\A\+?[0-9]{8,15}\z/)

          account_linking.user_for_phone(sender)
        end

        # The explicit link-a-different-number flow is unchanged.
        def start(sender:, phone:)
          account_linking.start(sender:, phone:)
        end

        def verify(sender:, code:)
          account_linking.verify(sender:, code:)
        end

        private

        attr_reader :organization, :account_linking
      end
    end
  end
end
