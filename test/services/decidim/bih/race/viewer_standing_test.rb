# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "active_support/core_ext/object/blank"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/race/viewer_standing"
require_relative "../../../../../app/services/decidim/bih/race/visibility"

module Decidim
  module Bih
    module Race
      class ViewerStandingTest < Minitest::Test
        # Visibility persistence belongs to the Rails harness. Exercise the real
        # reader with explicit read-only gate/version values in this unit suite.
        def run
          Visibility.stub(:visible?, ->(_org) { @race_visible != false }) { Visibility.stub(:version, ->(_org) { @visibility_version || 0 }) { super } }
        end

        Row = Struct.new(:komsiluk_id, :display_name, :zona, :rank_overall, :rank_in_zone, :score, :registered,
                         keyword_init: true)

        # The DB halves are the two methods a subclass replaces, exactly the way
        # AccountSummaryTest replaces its own. Everything above them — the
        # blank guards, the Summary shape, the cache sentinel and the rescue —
        # is what these tests are about.
        class TestStanding < ViewerStanding
          attr_reader :lookups

          def initialize(user, organization:, komsiluk_id: 7, row: nil, raise_with: nil)
            super(user, organization: organization)
            @komsiluk_id = komsiluk_id
            @row = row
            @raise_with = raise_with
            @lookups = 0
          end

          private

          def komsiluk_id
            @lookups += 1
            raise @raise_with if @raise_with

            @komsiluk_id
          end

          def standing_for(_komsiluk_id) = @row

          # No Rails in the engine's unit suite, so the cache is a plain hash
          # here. It still proves the sentinel round-trips and the block runs once.
          def cached
            @store ||= {}
            @store.fetch(cache_key) { @store[cache_key] = yield }
          end
        end

        def user = Struct.new(:id).new(42)

        def organization = Struct.new(:id).new(1)

        def full_row
          Row.new(komsiluk_id: 7, display_name: "Ledinci", zona: "selo", rank_overall: 9,
                  rank_in_zone: 3, score: 8, registered: 8)
        end

        def test_summary_carries_the_fields_the_nudge_renders
          summary = TestStanding.new(user, organization: organization, row: full_row).summary

          assert_equal 7, summary.komsiluk_id
          assert_equal "Ledinci", summary.display_name
          assert_equal "selo", summary.zona
          assert_equal 3, summary.rank_in_zone
          assert_equal 9, summary.rank_overall
          assert_equal 8, summary.score
          assert_equal 8, summary.registered
        end

        def test_manual_hide_suppresses_a_previously_cached_standing
          standing = TestStanding.new(user, organization: organization, row: full_row)
          refute_nil standing.summary
          @race_visible = false
          assert_nil standing.summary
          assert_equal 1, standing.lookups
        end

        def test_visibility_version_changes_the_cache_identity
          standing = TestStanding.new(user, organization: organization, row: full_row)
          before = standing.send(:cache_key)
          @visibility_version = 1
          refute_equal before, standing.send(:cache_key)
        end

        def test_no_user_or_no_organization_is_nil_and_never_looks_anything_up
          standing = TestStanding.new(nil, organization: organization, row: full_row)
          assert_nil standing.summary
          assert_equal 0, standing.lookups

          standing = TestStanding.new(user, organization: nil, row: full_row)
          assert_nil standing.summary
          assert_equal 0, standing.lookups
        end

        def test_a_citizen_with_no_komsiluk_gets_nothing
          assert_nil TestStanding.new(user, organization: organization, komsiluk_id: nil, row: full_row).summary
        end

        def test_a_komsiluk_with_no_standing_row_yet_gets_nothing
          assert_nil TestStanding.new(user, organization: organization, row: nil).summary
        end

        # This reader hangs on every page render for every signed-in citizen, so
        # a failure has to make the nudge disappear, never take the page with it.
        def test_a_raising_lookup_degrades_to_nil
          standing = TestStanding.new(user, organization: organization, raise_with: ActiveRecord::StatementInvalid)

          assert_nil standing.summary
        end

        # "No standing" is cached as a sentinel rather than as nil, so a citizen
        # whose komšiluk has no row does not re-query on every single page.
        def test_absence_is_cached_as_well_as_presence
          standing = TestStanding.new(user, organization: organization, row: nil)

          3.times { assert_nil standing.summary }
          assert_equal 1, standing.lookups

          present = TestStanding.new(user, organization: organization, row: full_row)
          3.times { refute_nil present.summary }
          assert_equal 1, present.lookups
        end

        def test_the_cache_key_separates_citizens_and_organizations
          a = TestStanding.new(user, organization: organization)
          b = TestStanding.new(Struct.new(:id).new(43), organization: organization)

          refute_equal a.send(:cache_key), b.send(:cache_key)
        end

        # The cached Summary carries a komšiluk name that was transliterated
        # into the active locale's script, so two locales must not share an
        # entry — otherwise a Cyrillic page can render a Latin komšiluk name.
        # The engine's unit suite boots without the host's locale list, so this
        # switches locales with enforcement off rather than asserting on names
        # that are only available inside a Rails app.
        def test_the_cache_key_separates_locales
          standing = TestStanding.new(user, organization: organization)
          previous = I18n.enforce_available_locales
          I18n.enforce_available_locales = false

          latin = I18n.with_locale(:sr) { standing.send(:cache_key) }
          cyrillic = I18n.with_locale(:"sr-Cyrl") { standing.send(:cache_key) }

          refute_equal latin, cyrillic
          assert_includes cyrillic, "sr-Cyrl"
        ensure
          I18n.enforce_available_locales = previous
        end
      end
    end
  end
end
