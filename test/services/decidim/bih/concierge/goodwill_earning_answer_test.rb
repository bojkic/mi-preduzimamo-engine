# frozen_string_literal: true

require "test_helper"
require "i18n"
require_relative "../../../../../app/services/decidim/bih/concierge/goodwill_earning_answer"

module Decidim
  module Bih
    module Concierge
      class GoodwillEarningAnswerTest < Minitest::Test
        # Stands in for Decidim::Bih::Goodwill::EarningRules: only the two
        # read-only methods the answer consults. Schedule order is the tie-break.
        class FakeRules
          attr_reader :schedule

          def initialize(schedule, caps)
            @schedule = schedule
            @caps = caps
          end

          def points_for(action) = @schedule[action.to_sym].to_i

          def cap_for(action) = @caps[action.to_sym]

          def cap_period_for(action) = action.to_sym == :proposal ? :month : :day
        end

        LOCALES = %w(sr sr-Cyrl bs hr en).freeze
        URL = "/biceriseno/zajednistvo?tab=kako"

        def setup
          @old_backend = I18n.backend
          @old_locales = I18n.available_locales
          @old_enforce = I18n.enforce_available_locales
          I18n.enforce_available_locales = false
          I18n.backend = I18n::Backend::Simple.new
          I18n.available_locales = LOCALES
          I18n.backend.load_translations(*LOCALES.map { |locale| File.expand_path("../../../../../config/locales/#{locale}.yml", __dir__) })
          @rules = FakeRules.new(
            { volunteer_hour: 100, volunteer_opportunity: 25, proposal: 25, referral: 25, report: 20, debate: 15,
              postal_verified: 40, komsiluk_selected: 10, verification: 10, comment: 3, like: 1 },
            { report: 5, proposal: 1, comment: 5, like: 10 }
          )
        end

        def teardown
          I18n.backend = @old_backend
          I18n.available_locales = @old_locales
          I18n.enforce_available_locales = @old_enforce
        end

        def test_lists_registration_then_the_highest_actions_from_the_effective_schedule
          lines = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL).lines.map(&:chomp)

          assert_equal I18n.t("decidim.bih.concierge.goodwill.earning.intro", locale: "sr"), lines.first
          assert_equal "#{I18n.t("decidim.bih.concierge.goodwill.earning.registration", locale: "sr")}: #{points(20)}", lines[1]
          assert_equal "#{label(:volunteer_hour)}: #{points(100)}", lines[2]
          assert_equal "#{label(:postal_verified)}: #{points(40)}", lines[3]
          assert_equal "#{label(:volunteer_opportunity)}: #{points(25)}", lines[4]
          assert_equal "#{label(:proposal)}: #{points(25)} (#{I18n.t("decidim.bih.concierge.goodwill.earning.monthly_cap", count: 1, locale: "sr")})", lines[5]
          assert_equal I18n.t("decidim.bih.concierge.goodwill.earning.note", locale: "sr"), lines[6]
          assert_equal "Sva pravila: #{URL}", lines.last
          assert_equal 8, lines.length
        end

        def test_registration_points_follow_the_schedule_not_a_literal
          rules = FakeRules.new({ verification: 15, komsiluk_selected: 25, report: 20 }, {})

          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules:, url: URL)

          assert_includes answer, "#{I18n.t("decidim.bih.concierge.goodwill.earning.registration", locale: "sr")}: #{points(40)}"
          refute_includes answer, points(10)
        end

        def test_zero_valued_actions_are_never_offered
          rules = FakeRules.new({ verification: 10, komsiluk_selected: 10, report: 20, like: 0, vote: 0 }, {})

          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules:, url: URL)

          refute_includes answer, label(:like)
          refute_includes answer, label(:vote)
          assert_includes answer, label(:report)
        end

        # R-1 (docs/operations/milica-effective-rules-2026-09-14.md §5): `referral`
        # ties at 25 with two actions that come earlier in the schedule, so the
        # top-five ranking dropped it — and "koliko bodova za poziv komšiji" was
        # unanswerable for exactly that reason.
        def test_a_named_action_is_answered_instead_of_the_top_five_ranking
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :referral)

          assert_includes answer, "#{label(:referral)}: #{points(25)}"
          refute_includes answer, label(:volunteer_hour)
          refute_includes answer, label(:postal_verified)
        end

        def test_proposals_show_the_monthly_cap_in_focused_and_limit_answers
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :proposal)
          expected = I18n.t("decidim.bih.concierge.goodwill.earning.monthly_cap", count: 1, locale: "sr")
          assert_includes answer, expected
          caps = GoodwillEarningAnswer.cap_values(organization: nil, locale: "sr", rules: @rules, url: URL)
          assert_includes caps.fetch(:caps), "#{label(:proposal)}: #{expected}"
        end

        def test_a_named_action_carries_its_own_daily_cap
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :report)

          assert_includes answer, "#{label(:report)}: #{points(20)} (#{I18n.t("decidim.bih.concierge.goodwill.earning.daily_cap", count: 5, locale: "sr")})"
        end

        # Registration is one experience and two schedule entries, and citizens
        # ask about one half at a time ("koliko za potvrdu telefona, a koliko za
        # izbor komšiluka") — so a named half answers both, separately.
        def test_naming_half_of_registration_answers_both_halves_separately
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :verification)

          assert_includes answer, "#{label(:verification)}: #{points(10)}"
          assert_includes answer, "#{label(:komsiluk_selected)}: #{points(10)}"
        end

        # "Koliko bodova dobijem za registraciju?" rendered two tens and never
        # said twenty. The total is the number the launch invitation is decided
        # on (the reward's cost equals it), so an answer that leaves the
        # citizen to add it up is the one thing this answer may not do.
        def test_naming_registration_states_the_total_and_both_halves
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :verification)
          lines = answer.lines.map(&:chomp)

          assert_equal "#{registration_label}: #{points(20)}", lines[1]
          assert_equal "#{label(:verification)}: #{points(10)}", lines[2]
          assert_equal "#{label(:komsiluk_selected)}: #{points(10)}", lines[3]
        end

        # The two routes a registration-points question can take — the named
        # action and the unnamed ranked list — state the SAME total, because it
        # is the same row computed the same way.
        def test_both_registration_routes_state_the_same_total
          named = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :komsiluk_selected)
          listed = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL)

          assert_equal listed.lines.map(&:chomp)[1], named.lines.map(&:chomp)[1]
        end

        # SUMMED, never typed: the total is whatever the effective schedule's
        # two registration entries add up to, so a host or per-organization
        # override moves it here without an edit.
        def test_the_registration_total_is_summed_from_the_schedule
          rules = FakeRules.new({ verification: 15, komsiluk_selected: 25, report: 20 }, {})
          expected = GoodwillEarningAnswer::REGISTRATION_ACTIONS.sum { |action| rules.points_for(action) }
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules:, url: URL, action: :verification)

          assert_equal 40, expected
          assert_includes answer, "#{registration_label}: #{points(expected)}"
          refute_includes answer, "#{registration_label}: #{points(20)}"
        end

        # A named action that is NOT half of registration gains no total.
        def test_a_named_action_outside_registration_gains_no_total_row
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :referral)

          refute_includes answer, registration_label
          assert_includes answer, "#{label(:referral)}: #{points(25)}"
        end

        def test_an_action_the_schedule_does_not_pay_for_falls_back_to_the_list
          answer = GoodwillEarningAnswer.call(organization: nil, locale: "sr", rules: @rules, url: URL, action: :budget_vote)

          assert_includes answer, label(:volunteer_hour)
          refute_includes answer, "#{label(:budget_vote)}: #{points(0)}"
        end

        def test_the_named_action_is_read_from_the_citizens_own_words
          assert_equal :referral, GoodwillEarningAnswer.requested_action("Koliko bodova dobijem za uspješan poziv komšiji?")
          assert_equal :report, GoodwillEarningAnswer.requested_action("koliko bodova nosi prijava problema")
          assert_equal :proposal, GoodwillEarningAnswer.requested_action("koliko bodova nosi prijedlog")
          assert_equal :volunteer_hour, GoodwillEarningAnswer.requested_action("koliko nosi volonterski sat")
          assert_nil GoodwillEarningAnswer.requested_action("kako da zaradim bodove")
          assert_nil GoodwillEarningAnswer.requested_action("")
        end

        # Every number in the referral answer comes from the code that pays it.
        def test_referral_values_read_the_schedule_and_the_documented_constants
          values = GoodwillEarningAnswer.referral_values(organization: nil, locale: "sr", rules: @rules, url: URL)

          assert_equal points(25), values.fetch(:points)
          assert_equal 24, values.fetch(:hours)
          assert_equal 10, values.fetch(:cap)
          assert_equal URL, values.fetch(:url)
        end

        def test_cap_values_list_only_the_actions_that_actually_have_a_cap
          values = GoodwillEarningAnswer.cap_values(organization: nil, locale: "sr", rules: @rules, url: URL)

          assert_includes values.fetch(:caps), "#{label(:report)}: #{I18n.t("decidim.bih.concierge.goodwill.earning.daily_cap", count: 5, locale: "sr")}"
          refute_includes values.fetch(:caps), label(:volunteer_hour)
          assert_equal URL, values.fetch(:url)
        end

        def test_every_locale_renders_without_missing_translations
          LOCALES.each do |locale|
            answer = GoodwillEarningAnswer.call(organization: nil, locale:, rules: @rules, url: URL)

            refute_match(/translation missing/i, answer, locale)
            assert_includes answer, URL, locale
            assert_includes answer, I18n.t("decidim.bih.goodwill.actions.volunteer_hour", locale:), locale
          end
          assert_match(/\p{Cyrillic}/, GoodwillEarningAnswer.call(organization: nil, locale: "sr-Cyrl", rules: @rules, url: URL))
        end

        private

        def points(count)
          I18n.t("decidim.bih.concierge.goodwill.earning.points", count:, locale: "sr")
        end

        def label(action)
          I18n.t("decidim.bih.goodwill.actions.#{action}", locale: "sr")
        end

        def registration_label
          I18n.t("decidim.bih.concierge.goodwill.earning.registration", locale: "sr")
        end
      end
    end
  end
end
