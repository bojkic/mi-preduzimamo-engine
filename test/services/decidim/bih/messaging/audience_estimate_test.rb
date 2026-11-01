# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/audience_estimate"

module Decidim
  module Bih
    module Messaging
      # The counts an operator is shown before a bulk send.
      #
      # The rule these tests exist for: a count comes from a DECISION, never
      # from a count of stored preference keys. Counting stored keys is exactly
      # what made six city-alert keys look like the whole audience.
      class AudienceEstimateTest < Minitest::Test
        Dec = Struct.new(:permitted, :reason_codes) do
          def permitted? = permitted
        end

        UNSUPPORTED = Dec.new(false, [:unsupported_channel])

        def estimate(decisions, channels: [:viber, :whatsapp], **rest)
          AudienceEstimate.compute(
            recipients: decisions.keys,
            channels:,
            decide: ->(recipient:, channel:) { decisions.fetch(recipient).fetch(channel, UNSUPPORTED) },
            cost_per_segment: 0.05,
            **rest
          )
        end

        # `to_h`, never `index_with`: this suite runs WITHOUT ActiveSupport, and
        # rubocop's Rails/IndexWith autocorrect silently breaks it. Kept as a
        # comment because the autocorrect will offer itself again.
        def permitted_everywhere(ids, channels: [:viber, :whatsapp]) # rubocop:disable Rails/IndexWith
          ids.to_h { |id| [id, channels.to_h { |channel| [channel, Dec.new(true, [])] }] }
        end

        def denied_everywhere(ids, reason, channels: [:viber, :whatsapp]) # rubocop:disable Rails/IndexWith
          ids.to_h { |id| [id, channels.to_h { |channel| [channel, Dec.new(false, [reason])] }] }
        end

        # --- counting -----------------------------------------------------

        def test_eligible_counts_recipients_not_channels
          assert_equal 1, estimate(permitted_everywhere([1]))[:eligible]
        end

        def test_one_permitted_channel_is_enough_to_be_eligible
          decisions = { 1 => { viber: Dec.new(false, [:channel_unconfigured]), whatsapp: Dec.new(true, []) } }
          result = estimate(decisions)
          assert_equal 1, result[:eligible]
          assert_equal 0, result[:undeliverable], "a recipient reachable on one channel is not undeliverable"
        end

        def test_suppressed_and_undeliverable_are_separate_reasons
          decisions = denied_everywhere([1], :transport_suppressed).merge(denied_everywhere([2], :destination_unknown))
          result = estimate(decisions)
          assert_equal 1, result[:suppressed]
          assert_equal 1, result[:undeliverable]
          assert_equal 0, result[:eligible]
        end

        # A citizen who said no is SUPPRESSED, not unreachable; conflating the
        # two turns a choice into a technical defect on the operator's screen.
        def test_an_explicit_preference_block_counts_as_suppressed_not_undeliverable
          result = estimate(denied_everywhere([1], :preference_blocked))
          assert_equal 1, result[:suppressed]
          assert_equal 0, result[:undeliverable]
        end

        # A reason nobody has classified must not be silently counted as a
        # citizen's choice. Unknown fails towards "we could not reach them".
        def test_an_unclassified_reason_counts_as_undeliverable_not_suppressed
          result = estimate(denied_everywhere([1], :some_reason_invented_tomorrow))
          assert_equal 0, result[:suppressed]
          assert_equal 1, result[:undeliverable]
        end

        # Suppression outranks a merely technical refusal on another channel:
        # a durable STOP is the operative fact about that recipient.
        def test_a_recipient_blocked_on_one_channel_and_suppressed_on_another_counts_once_as_suppressed
          decisions = { 1 => { viber: Dec.new(false, [:destination_unknown]), whatsapp: Dec.new(false, [:transport_suppressed]) } }
          result = estimate(decisions)
          assert_equal 1, result[:suppressed]
          assert_equal 0, result[:undeliverable]
          assert_equal 1, result[:recipients]
        end

        def test_every_recipient_lands_in_exactly_one_bucket
          decisions = permitted_everywhere([1, 2])
                      .merge(denied_everywhere([3], :transport_suppressed))
                      .merge(denied_everywhere([4], :destination_unknown))
          result = estimate(decisions)
          assert_equal 4, result[:recipients]
          assert_equal 4, result[:eligible] + result[:suppressed] + result[:undeliverable]
        end

        # --- the histogram ------------------------------------------------

        def test_the_reason_histogram_is_returned_without_identifiers
          result = estimate(denied_everywhere([7], :preference_blocked))
          assert_equal({ "preference_blocked" => 1 }, result[:by_reason])
          refute_includes result.to_s, "7", "a histogram must carry no recipient identifier"
        end

        def test_the_histogram_counts_a_recipient_once_per_reason_not_once_per_channel
          result = estimate(denied_everywhere([1], :destination_unknown))
          assert_equal({ "destination_unknown" => 1 }, result[:by_reason])
        end

        def test_the_histogram_is_stringified_although_reason_codes_are_symbols
          result = estimate(denied_everywhere([1], :transport_suppressed))
          assert_equal ["transport_suppressed"], result[:by_reason].keys
        end

        # --- cost ----------------------------------------------------------

        def test_cost_is_bounded_and_names_its_basis
          cost = estimate(permitted_everywhere(1..10))[:cost]
          assert_equal 10, cost[:segments], "one chain per recipient, not one per checked channel"
          assert_kind_of String, cost[:basis]
          assert_includes cost[:basis], "estimate"
        end

        def test_a_free_channel_is_never_billed
          cost = estimate(permitted_everywhere([1, 2], channels: [:bell]), channels: [:bell])[:cost]
          assert_equal 0, cost[:segments]
          assert_in_delta 0.0, cost[:amount], 0.0001
        end

        # An invented price is worse than no price: the operator would believe it.
        def test_an_unknown_unit_price_yields_no_amount_and_says_so
          cost = AudienceEstimate.compute(recipients: [1], channels: [:viber],
                                          decide: ->(recipient:, channel:) { Dec.new(true, []) },
                                          cost_per_segment: nil)[:cost]
          assert_equal 1, cost[:segments]
          assert_nil cost[:amount]
          assert cost[:degraded], "an estimate with no unit price must declare itself degraded"
        end

        def test_cost_amount_multiplies_billable_segments_by_the_unit_price
          cost = estimate(permitted_everywhere(1..4))[:cost]
          assert_in_delta 0.2, cost[:amount], 0.0001
          refute cost[:degraded]
        end

        # --- edges ---------------------------------------------------------

        def test_zero_recipients_produces_zeros_not_nil
          result = estimate({})
          assert_equal 0, result[:eligible]
          assert_equal({}, result[:by_reason])
          assert_equal 0, result[:cost][:segments]
        end

        def test_a_counted_estimate_says_that_it_counted
          assert estimate(permitted_everywhere([1]))[:counted]
        end

        # "Too many to count" must never render as zeros: a confident 0 reads
        # as "nobody is affected".
        def test_an_uncounted_audience_reports_the_population_and_no_buckets
          result = AudienceEstimate.uncounted(population: 5_000)
          assert_equal 5_000, result[:recipients]
          refute result[:counted]
          assert_nil result[:eligible]
          assert_nil result[:suppressed]
          assert_nil result[:undeliverable]
          assert_nil result.dig(:cost, :segments)
          assert result.dig(:cost, :degraded)
        end

        def test_an_estimate_is_not_a_guarantee_and_says_so
          assert_match(/ponovo provjerava/, AudienceEstimate::DISCLAIMER,
                       "the operator-facing copy is Serbian; it must say the send is rechecked")
        end

        def test_the_estimate_carries_the_disclaimer_with_it
          assert_equal AudienceEstimate::DISCLAIMER, estimate({})[:disclaimer]
        end

        # The composer must never compute a count from stored preference keys.
        def test_compute_asks_the_decider_for_every_recipient_and_channel
          asked = []
          AudienceEstimate.compute(
            recipients: [1, 2], channels: [:viber, :whatsapp],
            decide: lambda { |recipient:, channel:|
              asked << [recipient, channel]
              Dec.new(true, [])
            }
          )
          assert_equal [[1, :viber], [1, :whatsapp], [2, :viber], [2, :whatsapp]], asked
        end

        # A decider that raises for one recipient must not silently drop them
        # from the count — a smaller audience would read as "fewer people".
        def test_a_decider_failure_is_counted_as_undeliverable_and_named
          result = AudienceEstimate.compute(
            recipients: [1], channels: [:viber],
            decide: ->(recipient:, channel:) { raise "boom" }
          )
          assert_equal 1, result[:undeliverable]
          assert_equal({ "decision_unavailable" => 1 }, result[:by_reason])
        end
      end
    end
  end
end
