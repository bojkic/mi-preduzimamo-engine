# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Gifts wallet points from a citizen to a verified eligible organization.
      # Wallet-guarded (no overdraw); recognition is untouched (gifts aren't
      # earns). Broadcasts :ok(recipient, amount) / :invalid / :insufficient.
      class GiftPoints < Decidim::Command
        def initialize(user, recipient_id, amount, request_key: SecureRandom.uuid)
          @user = user
          @recipient_id = recipient_id
          # Coerce defensively: a crafted `amount[]=1` makes params[:amount] an
          # Array, and Array#to_i would raise. `.to_s.to_i` yields 0 (-> :invalid).
          @amount = amount
          @request_key = request_key
        end

        def call
          return broadcast(:invalid) if @user.blank?
          @amount = RequestIdentity.amount(@amount)
          key = RequestIdentity.key("gift", @user, @request_key)

          profile = Decidim::Bih::PartnerProfile
                    .goodwill_eligible
                    .where(organization: @user.organization)
                    .find_by(id: @recipient_id)
          # Self-transfer (and system-account/cross-org) are enforced by the
          # ledger (#transfer raises ArgumentError, rescued below to :invalid).
          return broadcast(:invalid) if profile.nil?

          recipient = PartnerOwner.owner_for(profile)
          Ledger.new.transfer(
            from_owner: @user, to_owner: recipient, amount: @amount,
            kind: "gift", reason: "gift", idempotency_key: key, metadata: { partner_profile_id: profile.id }
          )
          broadcast(:ok, profile, @amount)
        rescue Decidim::Bih::Goodwill::InsufficientBalanceError
          broadcast(:insufficient)
        rescue ArgumentError
          broadcast(:invalid)
        end
      end
    end
  end
end
