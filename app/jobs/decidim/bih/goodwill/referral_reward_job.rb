# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Settle an inviter queue after phone verification and neighborhood choice.
      # Durable pending reasons plus the periodic sweep survive missed jobs.
      class ReferralRewardJob < Decidim::ApplicationJob
        queue_as :goodwill

        # How long after the invitee's first verification the referrer is paid.
        # 24 hours since 2026-09-12 (owner decision; 48 hours before that). One
        # source: the authorization hook schedules with it and the "your
        # neighbour registered" notification quotes it.
        REWARD_DELAY = 24.hours

        retry_on ActiveRecord::Deadlocked,
                 ActiveRecord::LockWaitTimeout,
                 wait: :polynomially_longer,
                 attempts: 5
        discard_on ActiveJob::DeserializationError

        # `first_attempt` distinguishes the initial REWARD_DELAY run from the
        # 7-day retry so we never enqueue a third attempt.
        def perform(user_id:, first_attempt: true)
          invitee = Decidim::User.find_by(id: user_id)
          return if invitee.blank?

          Referrals.reward(invitee)
          referral = Referral.pending.find_by(invitee_id: invitee.id)
          # One bounded recovery job per attempt; the scheduled sweep is the
          # durable backstop if enqueue fails or a worker is lost.
          if referral&.next_attempt_at && first_attempt
            self.class.set(wait_until: referral.next_attempt_at).perform_later(user_id:, first_attempt: false)
          end
        end
      end
    end
  end
end
