# frozen_string_literal: true

require_relative "../concierge/answer_intents"

module Decidim
  module Bih
    module Admin
      # Bounded-window read model for the chat answer-quality alert.
      #
      # == Why this exists rather than another dashboard
      #
      # The operator-facing high/watch queue (+AnalyticsSummary#mi_bot_review+)
      # is CUMULATIVE over all time and has no date filter. `service`/`sr`
      # crossed into `high` on 2026-06-29, the first day ratings existed, and
      # has been `high` on all 78 days since. A weekly pointer that says the
      # same thing for eleven weeks carries no information about this week, so
      # it cannot raise a new alarm. This class answers a different question:
      # *did a bucket go bad in the last seven days?*
      #
      # The alert reuses the existing, authorized `operations_health_alert`
      # channel (script/mi_ops_health_smoke -> script/lib/mi_ops_notify.rb).
      # That channel already sends `daily` items once per day at 08:00
      # Europe/Sarajevo and reports recoveries, so the 24-hour deduplication
      # requirement is satisfied by construction rather than reimplemented.
      # An answer-quality regression is never `urgent`: it is not an outage. A
      # confirmed critical safety or identity defect escalates through the
      # existing incident process on its own merits, independently of rating
      # volume and of this threshold.
      #
      # == What the numbers are, and are not
      #
      # Every figure here is RATED-TURN FEEDBACK: turns on which somebody
      # clicked helpful or not helpful. It is not Milica's accuracy, not a
      # share of citizens and not a share of conversations, and it is never
      # divided by a usage total.
      #
      # A rating is also NOT a distinct citizen. `decidim_user_id` is NULL on
      # every rating row the platform has ever stored, the row is keyed by a
      # browser-session digest, and ratings arrive in bursts — the 2026-09-09
      # burst is 44 ratings from 4 sessions. Never label these counts as
      # people.
      #
      # == Why the bucket is answer_intent + locale, and not outcome
      #
      # The aggregate `outcome` column on feedback metadata is `success` on
      # 100% of rows recorded so far, including a row whose `answer_intent` is
      # `fallback`, because the dialogue used to label its refusals
      # "answered". Task 9b fixes the label going forward, but any rule keyed
      # on `outcome` would still be blind to every row already stored. The
      # bucket is therefore `answer_intent` x `locale`, which has always been
      # populated honestly.
      #
      # == Consent clicks are not ratings
      #
      # `ConciergeFeedback::VALUES` also carries `share_question` — the
      # citizen's consent to keep an unanswered question for review. It is not
      # a rating and must never enter either side of this ratio; counting it
      # would inflate the denominator and SUPPRESS an alert.
      class ChatFeedbackAlert
        WINDOW_DAYS = 7
        # Below this many rated turns a bucket has no usable evidence. It is
        # never reported as healthy and never reported as a percentage.
        MINIMUM_RATED = 5
        NEGATIVE_SHARE = 0.5
        # Only these two values are ratings.
        RATING_VALUES = %w(helpful not_helpful).freeze
        NEGATIVE_VALUE = "not_helpful"
        # The one label every consumer must carry, so no surface can quietly
        # present these counts as citizen accuracy.
        MEASURE = "rated_turn_feedback"
        INCIDENT_PREFIX = "chat_feedback"

        ALERT = "alert"
        BELOW_THRESHOLD = "below_threshold"
        INSUFFICIENT = "insufficient_rated_evidence"

        UNKNOWN = "unknown"
        LOCALE_FORMAT = /\A[a-zA-Z]{2,8}(-[a-zA-Z0-9]{2,8})*\z/

        # answer_intent and locale are read out of JSON metadata, so they are
        # bounded here rather than trusted: this row reaches an email.
        Bucket = Data.define(:answer_intent, :locale, :rated, :negative) do
          def negative_share
            rated.positive? ? negative.fdiv(rated) : 0.0
          end
        end

        class << self
          # The whole rule, with no database and no clock. Threshold changes
          # are tested here.
          def status(bucket, minimum_rated: MINIMUM_RATED, negative_share: NEGATIVE_SHARE)
            return INSUFFICIENT if bucket.rated < minimum_rated
            return ALERT if bucket.negative >= (bucket.rated * negative_share)

            BELOW_THRESHOLD
          end

          # Stable across runs and independent of the counts, so the alert
          # channel deduplicates on the BUCKET and a changed count alone never
          # re-notifies. Recovery is the same key disappearing.
          def incident_key(bucket)
            "#{INCIDENT_PREFIX}.#{bucket.answer_intent}.#{bucket.locale}"
          end

          def sanitize_intent(value)
            Decidim::Bih::Concierge::AnswerIntents.sanitize(value)
          end

          def sanitize_locale(value)
            value = value.to_s
            value.length <= 16 && value.match?(LOCALE_FORMAT) ? value : UNKNOWN
          end
        end

        # +counts+ is the seam the window is proved through: it receives the
        # range this run asked for and returns [intent, locale, rated,
        # negative] rows. It defaults to the feedback table.
        # rubocop:disable Metrics/ParameterLists
        def initialize(organization:, now: Time.current, window_days: WINDOW_DAYS,
                       minimum_rated: MINIMUM_RATED, negative_share: NEGATIVE_SHARE, counts: nil)
          @organization = organization
          @now = now
          @window_days = Integer(window_days)
          @minimum_rated = Integer(minimum_rated)
          @negative_share = Float(negative_share)
          @counts = counts
        end
        # rubocop:enable Metrics/ParameterLists

        attr_reader :organization, :now, :window_days, :minimum_rated, :negative_share

        def started_at = now - (window_days * 24 * 60 * 60)

        def range = started_at...now

        def buckets
          @buckets ||= raw_counts.filter_map do |intent, locale, rated, negative|
            rated = rated.to_i
            next if rated.zero?

            Bucket.new(answer_intent: self.class.sanitize_intent(intent), locale: self.class.sanitize_locale(locale),
                       rated:, negative: negative.to_i)
          end
        end

        # One row per bucket. Sorted worst-evidenced first so an operator reads
        # the firing buckets before the thin ones.
        def rows
          buckets.map { |bucket| row(bucket) }.sort_by { |row| sort_key(row) }
        end

        def alerting_rows
          rows.select { |row| row[:status] == ALERT }
        end

        def rated_turns_total = buckets.sum(&:rated)

        private

        def row(bucket)
          status = self.class.status(bucket, minimum_rated:, negative_share:)
          {
            measure: MEASURE,
            incident_key: self.class.incident_key(bucket),
            answer_intent: bucket.answer_intent,
            locale: bucket.locale,
            rated_turns: bucket.rated,
            negative_turns: bucket.negative,
            # Withheld below the minimum on purpose: a percentage of two
            # clicks reads as a measurement and is not one.
            negative_share_percent: status == INSUFFICIENT ? nil : (bucket.negative_share * 100).round,
            status:,
            window_days:,
            minimum_rated:,
            started_on: started_at.to_date.iso8601,
            ended_on: now.to_date.iso8601
          }
        end

        def sort_key(row)
          [{ ALERT => 0, BELOW_THRESHOLD => 1, INSUFFICIENT => 2 }.fetch(row[:status], 3),
           -row[:negative_turns], -row[:rated_turns], row[:answer_intent], row[:locale]]
        end

        def raw_counts
          return @counts.call(range) if @counts

          Decidim::Bih::ConciergeFeedback
            .where(organization:, value: RATING_VALUES, created_at: range)
            .group(Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')"), :locale)
            .pluck(
              Arel.sql("COALESCE(metadata->>'answer_intent', 'unknown')"),
              :locale,
              Arel.sql("COUNT(*)"),
              Arel.sql("COUNT(*) FILTER (WHERE value = 'not_helpful')")
            )
        end
      end
    end
  end
end
