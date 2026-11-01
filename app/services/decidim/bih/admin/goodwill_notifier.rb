# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Owns the "publish a goodwill bell notification, but never let a
      # notification failure break the already-committed admin action" shell that
      # the GoodwillController used to repeat inline. Every public method wraps a
      # single Decidim::EventsManager.publish in the same rescue-and-log guard:
      # a notification failure is swallowed (returns nil) and logged, exactly as
      # before — the status update / decision that triggered it has already been
      # committed and must not be rolled back.
      #
      # One method per event; each preserves EXACTLY the event class, event name,
      # resource, affected_users and extra payload of the original call site.
      class GoodwillNotifier
        # Bell notification to the citizen when their reward is reserved
        # (stock/seat/coupon held for follow-up).
        def reward_reserved(fulfillment)
          reward = Decidim::Bih::Goodwill::RewardsCatalog.find(fulfillment.reward_key, fulfillment.organization)

          guard("reward_reserved", "fulfillment #{fulfillment.id}") do
            Decidim::EventsManager.publish(
              event: "decidim.events.bih.goodwill.reward_reserved",
              event_class: Decidim::Bih::Goodwill::RewardReservedEvent,
              resource: fulfillment.user,
              affected_users: [fulfillment.user],
              force_send: true,
              extra: {
                reward_name: reward&.name || fulfillment.reward_key,
                fulfillment: reward&.fulfillment.to_s
              }
            )
          end
        end

        # Bell notification to the citizen when their reward is fulfilled
        # (delivered).
        def reward_fulfilled(fulfillment)
          reward = Decidim::Bih::Goodwill::RewardsCatalog.find(fulfillment.reward_key, fulfillment.organization)

          guard("reward_fulfilled", "fulfillment #{fulfillment.id}") do
            Decidim::EventsManager.publish(
              event: "decidim.events.bih.goodwill.reward_fulfilled",
              event_class: Decidim::Bih::Goodwill::RewardFulfilledEvent,
              resource: fulfillment.user,
              affected_users: [fulfillment.user],
              force_send: true,
              extra: {
                reward_name: reward&.name || fulfillment.reward_key,
                fulfillment: reward&.fulfillment.to_s
              }
            )
          end
        end

        # Bell notification to the citizen when their reward is canceled
        # (points refunded).
        def reward_canceled(fulfillment)
          reward = Decidim::Bih::Goodwill::RewardsCatalog.find(fulfillment.reward_key, fulfillment.organization)

          guard("reward_canceled", "fulfillment #{fulfillment.id}") do
            Decidim::EventsManager.publish(
              event: "decidim.events.bih.goodwill.reward_canceled",
              event_class: Decidim::Bih::Goodwill::RewardCanceledEvent,
              resource: fulfillment.user,
              affected_users: [fulfillment.user],
              force_send: true,
              extra: {
                reward_name: reward&.name || fulfillment.reward_key,
                refunded: fulfillment.auto_issued? ? 0 : fulfillment.cost
              }
            )
          end
        end

        # Bell notification to the match request owner when the admin approves
        # or rejects their request. No-op unless the owner is a Decidim::User.
        def match_request_decided(request, decision)
          owner = request.owner
          return unless owner.is_a?(Decidim::User)

          guard("match_request_decided", "request #{request.id}") do
            Decidim::EventsManager.publish(
              event: "decidim.events.bih.goodwill.match_request_decided",
              event_class: Decidim::Bih::Goodwill::MatchRequestDecidedEvent,
              resource: owner,
              affected_users: [owner],
              force_send: true,
              extra: {
                decision:,
                points: request.points
              }
            )
          end
        end

        private

        # The shared rescue shell: a notification failure must never bubble up
        # after the triggering action has already committed. Swallow + log, and
        # return nil (matching the previous inline behaviour).
        def guard(label, subject)
          yield
        rescue StandardError => e
          Rails.logger.error(
            "[Admin::Goodwill] #{label} notification failed for #{subject}: #{e.class}: #{e.message}"
          )
          nil
        end
      end
    end
  end
end
