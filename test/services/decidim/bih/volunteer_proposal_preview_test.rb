# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require_relative "../../../../app/services/decidim/bih/volunteer_schedule"
require_relative "../../../../app/services/decidim/bih/volunteer_proposal_preview"

module Decidim
  module Bih
    class VolunteerProposalPreviewTest < Minitest::Test
      def test_realistic_long_programme_shows_five_local_dates_all_overlaps_and_dst_difference
        preview = VolunteerProposalPreview.build(
          starts_at: "2026-09-13T20:23", ends_at: "2027-01-07T20:23",
          signup_deadline_at: nil, recurrence_count: 5, maximum: 8
        )

        assert_equal 5, preview.terms.size
        assert_equal "2026-09-13 20:23", preview.terms.first.starts_at.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%d %H:%M")
        assert_equal "2026-10-11 20:23", preview.terms.last.starts_at.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%d %H:%M")
        assert_equal 2784, preview.terms.first.local_hours
        assert_equal 2785, preview.terms.first.elapsed_hours
        assert_equal 5, preview.long_terms.size
        assert_equal 10, preview.overlaps.size
        assert_includes preview.overlaps, [1, 5]
      end

      def test_short_adjacent_sessions_have_no_false_long_or_overlap_warning
        preview = VolunteerProposalPreview.build(
          starts_at: "2026-09-25T10:00", ends_at: "2026-09-25T11:00",
          signup_deadline_at: "2026-09-24T18:00", recurrence_count: 2, maximum: 8
        )

        assert_equal [1, 1], preview.terms.map(&:local_hours)
        assert_empty preview.long_terms
        assert_empty preview.overlaps
        assert_equal "2026-10-01 18:00",
                     preview.terms.last.signup_deadline_at.in_time_zone("Europe/Sarajevo").strftime("%Y-%m-%d %H:%M")
      end

      def test_preview_digest_preserves_all_field_values_and_ordered_multiple_choices
        first = { "title" => "Park", "starts_at" => "2026-09-25T10:00",
                  "opportunity_day_keys" => ["mon", "fri"], "requirements" => "Bring gloves" }
        same_with_reordered_keys = first.to_a.reverse.to_h
        changed_schedule = first.merge("starts_at" => "2026-09-25T11:00")
        changed_choice = first.merge("opportunity_day_keys" => ["fri", "mon"])
        changed_text = first.merge("requirements" => "Bring bags")

        digest = VolunteerProposalPreview.digest(first)
        assert_equal digest, VolunteerProposalPreview.digest(same_with_reordered_keys)
        refute_equal digest, VolunteerProposalPreview.digest(changed_schedule)
        refute_equal digest, VolunteerProposalPreview.digest(changed_choice)
        refute_equal digest, VolunteerProposalPreview.digest(changed_text)
      end
    end
  end
end
