# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Subscribes goodwill point-awarding to the reliable ActiveSupport
      # notification seams that exist in Decidim 0.31.7. Subscribers only LOCATE
      # the actor and ENQUEUE GoodwillAwardJob — no ledger work happens inline, so
      # the user-facing request stays fast and a failure never breaks the action.
      #
      # Installed ONCE from the engine initializer (not to_prepare, which would
      # duplicate subscriptions on every dev reload). The blocks reference the job
      # and models by constant name, so Zeitwerk reloading resolves them freshly.
      #
      # SEAMS USED (verified for 0.31.7):
      #   * "decidim.comments.comment_created"               => :comment
      #   * "decidim.events.proposals.proposal_published"    => :proposal
      #   * "decidim.events.resource_liked"                  => :like (extra[:liker_id])
      #   * "decidim.events.debates.debate_created"          => :debate
      #
      # Wired via model override (no AS notification in 0.31.7):
      #   proposal votes  → ProposalVoteAwardOverride (after_create_commit)
      #   budget checkout → BudgetVoteAwardOverride   (after_update_commit)
      #   authorization   → AuthorizationReferralOverride (after_save)
      #   civic reports   → ReportIntake#award_contribution (inline, sync)
      module EventSubscriptions
        # Centralised so the topic strings live in ONE place (a Decidim upgrade
        # that renames an event would otherwise silently stop awards). A test
        # (event_subscriptions_test) asserts each topic still has a publisher.
        EVENT_NAMES = {
          comment: "decidim.comments.comment_created",
          proposal: "decidim.events.proposals.proposal_published",
          like: "decidim.events.resource_liked",
          debate: "decidim.events.debates.debate_created"
        }.freeze

        module_function

        def install!
          subscribe_comment_created
          subscribe_proposal_published
          subscribe_resource_liked
          subscribe_debate_created
        end

        def subscribe_comment_created
          ActiveSupport::Notifications.subscribe(EVENT_NAMES[:comment]) do |_name, data|
            safely do
              comment = Decidim::Comments::Comment.find_by(id: data[:comment_id])
              author = comment&.author
              next unless author.is_a?(Decidim::UserBaseEntity)

              AwardDispatch.comment_created(comment, author:)
            end
          end
        end

        def subscribe_proposal_published
          ActiveSupport::Notifications.subscribe(EVENT_NAMES[:proposal]) do |_name, data|
            safely do
              # proposal_published is broadcast twice; skip the space-wide republish.
              next if data.dig(:extra, :participatory_space)

              proposal = data[:resource]
              next unless proposal.respond_to?(:authors)

              proposal.authors.each do |author|
                next unless author.is_a?(Decidim::UserBaseEntity)

                AwardDispatch.proposal_published(proposal, author:)
              end
            end
          end
        end

        def subscribe_resource_liked
          ActiveSupport::Notifications.subscribe(EVENT_NAMES[:like]) do |_name, data|
            safely do
              liker = Decidim::User.find_by(id: data.dig(:extra, :liker_id))
              next unless liker

              resource = data[:resource]
              AwardDispatch.resource_liked(resource, liker:)
            end
          end
        end

        # Award the debate author when they create a new debate. The
        # "decidim.events.debates.debate_created" notification is published
        # TWICE by CreateDebate (once for author followers, once for space
        # followers); the extra[:type] discriminator lets us fire only once.
        def subscribe_debate_created
          ActiveSupport::Notifications.subscribe(EVENT_NAMES[:debate]) do |_name, data|
            safely do
              # Fire only on the "user" notification (author's followers), not the
              # space-followers copy — otherwise the author earns twice per debate.
              next unless data.dig(:extra, :type) == "user"

              debate = data[:resource]
              next unless debate.respond_to?(:author)

              author = debate.author
              next unless author.is_a?(Decidim::UserBaseEntity)

              AwardDispatch.debate_created(debate, author:)
            end
          end
        end

        def safely
          yield
        rescue StandardError => e
          Rails.logger.error("[goodwill] subscriber error: #{e.class}: #{e.message}")
          nil
        end
      end
    end
  end
end
