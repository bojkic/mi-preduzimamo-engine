# frozen_string_literal: true

module Decidim
  module Bih
    # Security secret expiry, independent of optional operator retention sweeps.
    class ExpireChannelConnectionChallengeJob < Decidim::ApplicationJob
      queue_as :default

      def perform(challenge_id)
        challenge = ChannelConnectionChallenge.find_by(id: challenge_id)
        return unless challenge

        challenge.with_lock do
          if challenge.expires_at > Time.current
            self.class.set(wait_until: challenge.expires_at).perform_later(challenge.id)
            next
          end

          challenge.update!(recipient_ciphertext: nil, confirmation_digest: nil, consumed_at: challenge.consumed_at || Time.current)
        end
      end
    end
  end
end
