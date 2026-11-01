# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Poništava pozivnice koje nisu potvrđene u roku od 72 sata i time ih
      # vraća u zalihu — status "canceled" oslobađa mjesto u remaining_stock.
      class ExpireLaunchInvitationsJob < ActiveJob::Base
        queue_as :default

        def perform
          scope = RewardFulfillment
                  .where(reward_key: LaunchInvitation::REWARD_KEY,
                         auto_issued: true,
                         attendance_confirmed_at: nil,
                         status: RewardFulfillment::OPEN_STATUSES)
                  .where(confirmation_deadline_at: ...Time.current)

          voided = 0
          scope.find_each do |invitation|
            next unless invitation.mark!(
              "canceled",
              by: nil,
              source: "system",
              actor_role: "system",
              metadata: { action: "confirmation_deadline_missed" }
            )

            voided += 1
          end

          # Samo agregat — nikad kodovi, imena ni kontakti.
          Rails.logger.info("[launch_invitation] poništeno nepotvrđenih: #{voided}")
          voided
        end
      end
    end
  end
end
