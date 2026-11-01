# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The recheck that runs immediately before an irreversible send.
      #
      # ⚠️ This is an ADDITION to the checks each surface already performs, and
      # never a replacement for them. The one failure mode this phase exists to
      # avoid is moving a send-time check to compose time: a preview that
      # renders "you may send this" is a photograph of a moment, and governance,
      # authorization, readiness and the audience can all move between that
      # moment and the button. So there is deliberately no compose-time variant
      # and no skip — the readiness banner calls the SAME {evaluate}, with the
      # facts it can establish then, and the dispatch path calls it again with
      # the facts that are true at the send.
      #
      # {evaluate} is a pure function over booleans the callers supply, which
      # is what lets it live in the pure suite and what stops it quietly
      # acquiring a database read, a provider call or a write.
      #
      # What it does NOT do, stated so nobody assumes it: it makes no
      # per-recipient decision. A bulk audience is re-resolved and re-decided
      # per citizen inside the dispatch path itself (`KomsilukBroadcast#call`
      # re-resolves recipient ids; `AccountNotifications.dispatch!` re-previews
      # eligibility inside the claim). This guard answers the operator-level
      # questions — may this person send, is the decision still current, is the
      # preview still the thing being sent, is the channel ready, has the
      # audience moved, has the window passed.
      module DispatchGuard
        # Every fact the guard checks, mapped to the blocker it produces.
        # Iterating this is what makes "a check nobody can fail" a test
        # failure rather than a comment.
        #
        # All of them read "true means fine" EXCEPT {EXPIRY_CHECK}, which reads
        # the other way round because the caller asks "has it expired?".
        CHECKS = {
          authorized: :not_authorized,
          governance_current: :governance_missing,
          preview_fresh: :preview_expired,
          preview_matches: :preview_mismatch,
          audience_unchanged: :audience_changed,
          expired: :expired,
          channel_ready: :channel_not_ready
        }.freeze

        EXPIRY_CHECK = :expired

        # How long a rendered preview may be acted on. The operator-message
        # surface already enforces exactly this with a signed token
        # (`purpose: "operator_delivery", expires_in: 10.minutes`); the constant
        # is named here so the other surfaces do not each invent their own.
        PREVIEW_TTL_SECONDS = 600

        # A refusal, with every reason it was refused for. An operator who is
        # told one blocker, fixes it, and is then told a second has been made
        # to guess at their own permissions.
        class Result
          attr_reader :blockers

          def initialize(blockers)
            @blockers = blockers.freeze
            freeze
          end

          def allowed? = blockers.empty?

          def blocked? = !allowed?

          # Aggregate-safe: reason codes only, never an actor, a recipient or a
          # destination.
          def to_h = { allowed: allowed?, blockers: }
        end

        module_function

        # Every keyword is required on purpose. A caller that cannot establish
        # a fact must say so by passing `nil`, which BLOCKS — not by leaving it
        # out and being defaulted into a send.
        # rubocop:disable Metrics/ParameterLists
        def evaluate(authorized:, governance_current:, preview_fresh:, preview_matches:,
                     audience_unchanged:, expired:, channel_ready:)
          facts = { authorized:, governance_current:, preview_fresh:, preview_matches:,
                    audience_unchanged:, expired:, channel_ready: }

          Result.new(
            CHECKS.filter_map do |name, blocker|
              blocker if failed?(name, facts.fetch(name))
            end
          )
        end
        # rubocop:enable Metrics/ParameterLists

        # Unknown is not permission. `nil` — a collaborator that raised, a
        # setting that could not be read, a token that could not be parsed —
        # blocks in every direction.
        def failed?(name, value)
          return value != false if name == EXPIRY_CHECK

          value != true
        end

        # ⚠️ There is deliberately NO Rails-side gatherer here that resolves a
        # governance approval, an operator audit event or chat feedback.
        # `Messaging::*` must not reach into those ledgers - they are
        # independent records with their own retention and access rules, and
        # `messaging_attempts_test.rb` asserts the whole directory stays clean
        # of them. Each surface resolves its own governance and passes the
        # boolean in, which is also where the knowledge of WHICH approval kind
        # governs that surface already lives.
      end
    end
  end
end
