# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # What is stuck, what is genuinely unknown, what expired, what was skipped
      # and why — as counts an operator can act on.
      #
      # Two things this is NOT, and both are refusals rather than omissions:
      #
      #   * It does not mutate. No requeue, no resend, no "clean up". In
      #     particular it never resets an `uncertain` attempt to `queued`: an
      #     uncertain outcome means the provider MAY already have done the work,
      #     and turning it back into pending is how one message becomes two paid
      #     messages to make a dashboard look tidy.
      #   * It does not drain a provider report queue. The existing per-intent
      #     caller (`AccountNotifications.reconcile!`) asks for reports BY
      #     MESSAGE ID and the Messages API hands each report over once; a bulk
      #     drain would consume those reports and leave the per-intent caller
      #     with nothing to find.
      #
      # {classify} is a pure function over row-like objects — no Rails, no
      # database — so the classification rules can be tested without a schema
      # and cannot quietly acquire a write.
      module Reconciliation
        STUCK_AFTER = 1800 # seconds; a claim with no settlement this long is stuck
        UNRESOLVED_STATUSES = %w(queued claimed).freeze

        module_function

        # @param rows [Enumerable] anything answering #status #reason #channel
        #   #channel_group #claimed_at #settled_at
        # @return [Hash] counts and histograms only. No identifier of any kind.
        # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        # -- one flat hash of independent counters. Every branch is a
        # separate question an operator asks, and folding them into helpers
        # would hide which questions this report actually answers.
        def classify(rows, now:, stuck_after: STUCK_AFTER, expected_classes: [], orphan_intents: 0,
                     observed_classes: [])
          rows = rows.to_a
          {
            attempts: rows.size,
            by_status: tally(rows) { |row| row.status.to_s },
            by_channel: tally(rows) { |row| row.channel.to_s },
            stuck: rows.count { |row| stuck?(row, now, stuck_after) },
            unknown: rows.count { |row| row.status.to_s == "uncertain" },
            failed: rows.count { |row| row.status.to_s == "failed" },
            expired: rows.count { |row| row.status.to_s == "expired" },
            skipped: rows.count { |row| row.status.to_s == "skipped" },
            reasons: tally(rows.reject { |row| row.reason.to_s.empty? }) { |row| row.reason.to_s },
            # A correlation gap is REPORTED, never repaired. An intent with no
            # attempt may be a producer that failed to record, or a decision
            # that legitimately sent nothing; guessing between those in a
            # maintenance job is how invented history starts.
            intents_without_attempts: orphan_intents.to_i,
            # Not "idle": a class with no attempts is an unenrolled producer
            # that still keeps its own evidence.
            classes_without_attempts: (expected_classes.map(&:to_s) - observed_classes.map(&:to_s)).uniq.sort
          }
        end
        # rubocop:enable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        # Stuck is a CLAIM that never became an outcome. An accepted or
        # uncertain leg is not stuck however old it is — it has an answer, and
        # calling it stuck would invite somebody to re-run it.
        #
        # There is deliberately no second `settled_at` test here: every settle
        # writes a status out of UNRESOLVED_STATUSES, so a settled row is
        # already excluded by the first line. A redundant guard reads like a
        # protection and is not one.
        def stuck?(row, now, stuck_after)
          return false unless UNRESOLVED_STATUSES.include?(row.status.to_s)
          return false if row.claimed_at.nil?

          (now.to_i - row.claimed_at.to_i) >= stuck_after
        end

        def tally(rows)
          rows.each_with_object(Hash.new(0)) { |row, counts| counts[yield(row)] += 1 }.sort.to_h
        end

        # ---- the Rails entry point ------------------------------------------

        # Read-only by construction: aggregate selects and a classification. It takes
        # no lock, enqueues nothing and calls no provider.
        def report(organization:, since: 30.days.ago, now: Time.current)
          intents = Intent.where(organization:).where(created_at: since..)
          attempts = Attempt.where(intent_id: intents.select(:id))
          # `enrolled` is a Hash of key => Entry, not a list of entries.
          observed = attempts.joins(:intent).distinct.pluck("decidim_bih_messaging_intents.message_class")
          summary = classify(attempts.to_a,
                             now:,
                             expected_classes: MessageClass.enrolled.keys,
                             observed_classes: observed,
                             orphan_intents: intents.where.not(id: attempts.select(:intent_id)).count)
          uncertain_report_push = Decidim::Notification
                                  .where(decidim_user_id: Decidim::User.where(organization:).select(:id))
                                  .where(created_at: since..)
                                  .where("extra ->> 'mi_report_push_claim' = ?", "uncertain")
                                  .count
          summary.merge(
            # Historical claim uncertainty since `since`; a later settled leg
            # does not erase the original ambiguity or authorize a replay.
            report_push_claim_uncertain_recorded: uncertain_report_push,
            organization_host: organization.host,
            since: since.utc.iso8601,
            generated_at: now.utc.iso8601,
            intents: intents.count,
            suppressions_blocking: Suppression.blocking(now).where(organization:).count
          )
        end
      end
    end
  end
end
