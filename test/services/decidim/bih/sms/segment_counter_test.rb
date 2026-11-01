# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/sms/segment_counter"

module Decidim
  module Bih
    module Sms
      class SegmentCounterTest < Minitest::Test
        def test_plain_latin_text_is_gsm7
          result = SegmentCounter.for("MI: Vidimo se veceras u Centru za kulturu.")

          assert_equal :gsm7, result[:encoding]
          assert_equal 1, result[:segments]
        end

        # This is the whole point of the exercise: our letters leave GSM-7 and
        # drop the per-SMS budget from 160 characters to 70.
        def test_our_diacritics_force_ucs2
          result = SegmentCounter.for("Vidimo se večeras")

          assert_equal :ucs2, result[:encoding]
        end

        def test_gsm7_boundary_at_160_characters
          assert_equal 1, SegmentCounter.for("a" * 160)[:segments]
          assert_equal 2, SegmentCounter.for("a" * 161)[:segments], "multipart GSM-7 carries 153 per part"
          assert_equal 2, SegmentCounter.for("a" * 306)[:segments]
          assert_equal 3, SegmentCounter.for("a" * 307)[:segments]
        end

        def test_ucs2_boundary_at_70_characters
          assert_equal 1, SegmentCounter.for("č" * 70)[:segments]
          assert_equal 2, SegmentCounter.for("č" * 71)[:segments], "multipart UCS-2 carries 67 per part"
        end

        # UCS-2/UTF-16 bills 16-bit code units, not Ruby codepoints. An
        # astral-plane character like an emoji (U+1F600, outside the Basic
        # Multilingual Plane) is encoded as a surrogate pair: TWO code units,
        # not one.
        def test_astral_plane_character_counts_as_two_units
          result = SegmentCounter.for("\u{1F600}")

          assert_equal :ucs2, result[:encoding]
          assert_equal 2, result[:characters]
        end

        # Derivation: each emoji is one astral-plane codepoint = 2 UTF-16
        # code units. UCS2_SINGLE is 70 units, so 35 emoji = 35 * 2 = 70
        # units exactly, landing on the single-segment boundary. One more
        # emoji, 36 * 2 = 72 units, crosses it: 72 > 70, so it falls into the
        # multipart formula, ceil(72 / 67) = 2 segments.
        def test_ucs2_boundary_shifts_correctly_for_astral_plane_characters
          emoji = "\u{1F600}"

          assert_equal 70, SegmentCounter.for(emoji * 35)[:characters]
          assert_equal 1, SegmentCounter.for(emoji * 35)[:segments]

          assert_equal 72, SegmentCounter.for(emoji * 36)[:characters]
          assert_equal 2, SegmentCounter.for(emoji * 36)[:segments]
        end

        # A 150-character message with our letters costs three SMS; without
        # them, one. That is the number the operator needs before a mass send.
        def test_the_same_message_costs_three_segments_with_diacritics_and_one_without
          with = "š" * 150
          without = "s" * 150

          assert_equal 3, SegmentCounter.for(with)[:segments]
          assert_equal 1, SegmentCounter.for(without)[:segments]
        end

        def test_extension_characters_count_double_in_gsm7
          result = SegmentCounter.for("€" * 80)

          assert_equal :gsm7, result[:encoding]
          assert_equal 160, result[:characters]
          assert_equal 1, result[:segments]
        end

        def test_empty_text_is_a_single_empty_segment
          assert_equal 1, SegmentCounter.for("")[:segments]
        end
      end
    end
  end
end
