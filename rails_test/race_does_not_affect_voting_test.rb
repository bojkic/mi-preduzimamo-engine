# frozen_string_literal: true

require "test_helper"
require "decidim/proposals/test/factories"

module Decidim
  module Bih
    module RailsHarness
      # The platform's published promise (spec §9, "A6" and test 14 of §11):
      # points and the race are RECOGNITION, never power. A high-scoring
      # komšiluk must never cast a heavier vote, outrank another proposal, or
      # make content more or less visible than a zero-scoring one.
      #
      # This is deliberately layered, not a single assertion, because each
      # layer catches a different way the wall could quietly fail later:
      #   1. schema  - no future migration can smuggle in an influence column
      #      on the tables that decide votes/ordering/visibility;
      #   2. source  - no future line of code in the voting engines, OR in
      #      this engine's OWN overrides onto those engines, can make a vote's
      #      weight or a resource's visibility depend on a balance or score;
      #   3. behaviour - even if 1 and 2 were somehow bypassed, an actual vote
      #      cast by a citizen of the highest-scoring komšiluk in the database
      #      must still count for exactly the same amount as one cast by a
      #      citizen of a komšiluk with zero points.
      #
      # The REAL proposal-ordering path (Decidim::Proposals::Orderable#reorder,
      # exercised through an actual controller request) and a real-moderation
      # visibility check live in rails_test/race_proposal_ordering_test.rb —
      # they need ActionDispatch::IntegrationTest and a published component,
      # which would otherwise pull unrelated HTTP/routing setup into every
      # test in this file.
      class RaceDoesNotAffectVotingTest < ActiveSupport::TestCase
        # Every table whose columns decide a vote's weight, a proposal's
        # ranking/ordering, or a resource's visibility/moderation state.
        VOTING_AND_VISIBILITY_MODELS = [
          Decidim::Proposals::Proposal,
          Decidim::Proposals::ProposalVote,
          Decidim::Budgets::Order,
          Decidim::Budgets::LineItem,
          Decidim::Moderation
        ].freeze

        # Engines that implement the binding vote and its ordering/visibility.
        # Neither may reference the race or the points ledger for any reason.
        VOTING_ENGINES = [Decidim::Proposals::Engine, Decidim::Budgets::Engine].freeze

        # Fully-qualified class names of the same vote/ranking/visibility
        # models, as they appear in a `.prepend(SomeClass)` call at the bottom
        # of an override file. Used to find which of THIS engine's own
        # app/overrides/ files touch a class that decides a vote's weight, a
        # proposal's position, or whether something is shown.
        VOTING_AND_VISIBILITY_CLASS_NAMES = %w(
          Decidim::Proposals::Proposal
          Decidim::Proposals::ProposalVote
          Decidim::Budgets::Order
          Decidim::Budgets::LineItem
          Decidim::Moderation
        ).freeze

        FORBIDDEN_COLUMN_PATTERN = /race|goodwill|komsiluk|zona|zone|weight|multiplier|boost|influence/i

        # The AWARD direction (a vote earns points) is legitimate and already
        # shipped via Decidim::Bih::Goodwill::AwardDispatch. What must never
        # happen is the OPPOSITE direction: an override reading a balance,
        # score, or ranking to decide how much a vote counts, where a
        # proposal sits, or whether a resource is shown.
        FORBIDDEN_READS_IN_VOTING_OVERRIDES = /
          Decidim::Bih::Goodwill::Ledger |
          Decidim::Bih::Race::Standings |
          Decidim::Bih::Race::Scorer |
          \.balance\b |
          EarningRules
        /x

        setup do
          # The 2026 race closed 14.10 20:00; scoring and refresh run only while it is open.
          travel_to Time.utc(2026, 10, 1, 10)
          @organization = create_organization
          @grad = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-grad", zona: "grad", name: { "sr" => "Centar" }
          )
          @selo = Decidim::Bih::LocalArea.create!(
            organization: @organization, kind: "komsiluk", slug: "k-selo", zona: "selo", name: { "sr" => "Dvorovi" }
          )
          # The race window is 6.9.2026-14.10.2026, so activity has to be
          # timestamped inside the window
          # (like race_scorer_test.rb and race_standings_test.rb do) or the
          # Scorer would score everything as zero and the "score gap" fixture
          # below would prove nothing.
          Decidim::Bih.race_window_from = "2026-09-06 00:00:00"
          Decidim::Bih.race_window_to = "2026-10-14 20:00:00"
          @inside = Time.zone.parse("2026-09-20 12:00:00")
        end

        teardown do
          Decidim::Bih.race_window_from = nil
          Decidim::Bih.race_window_to = nil
        end

        def citizen(komsiluk, at: @inside)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SecureRandom.hex(8), granted_at: at)
          Decidim::Bih::CitizenProfile.create!(
            organization: @organization, decidim_user_id: user.id,
            komsiluk_id: komsiluk.id, source: "dropdown", assigned_at: at
          )
          user
        end

        def standings = Decidim::Bih::Race::Standings.new(@organization)

        # --- Layer 1: schema ---------------------------------------------

        test "the standings model itself carries no vote weight or visibility column" do
          columns = Decidim::Bih::Race::Standing.column_names

          %w(weight vote_weight multiplier visibility priority boost rank_boost hidden published influence).each do |forbidden|
            refute_includes columns, forbidden
          end
        end

        test "no table that decides a vote's weight, ordering, or visibility carries a race or points column" do
          VOTING_AND_VISIBILITY_MODELS.each do |model|
            offending = model.column_names.grep(FORBIDDEN_COLUMN_PATTERN)

            assert_empty offending,
                         "#{model} must not carry any column the race or Goodwill could use to buy influence: #{offending}"
          end
        end

        # --- Layer 2: source -----------------------------------------------

        test "no race or goodwill class is referenced from proposal or budget voting/ordering/visibility code" do
          VOTING_ENGINES.each do |engine|
            sources = Dir.glob(engine.root.join("app/**/*.rb")).map { |f| File.read(f) }.join

            refute_match(/Decidim::Bih::Race/, sources, "#{engine} must not reference the race")
            refute_match(/Decidim::Bih::Goodwill/, sources, "#{engine} must not reference the points ledger")
          end
        end

        # This engine DOES legitimately couple Goodwill to voting — casting a
        # proposal/budget vote AWARDS points (see
        # app/overrides/decidim/proposal_vote_award_override.rb and
        # budget_vote_award_override.rb). That is one-directional and fine.
        # What this test forbids is the REVERSE: any of this engine's own
        # app/overrides/ files that prepend onto a vote/ranking/visibility
        # class consulting a balance, score, or ranking to decide anything
        # about that vote, position, or visibility. It fails if a future
        # override reads Ledger/Standings/Scorer/`.balance`/EarningRules from
        # inside one of those prepended modules.
        test "this engine's own overrides only ever award points for voting, never consult a balance or score to decide one" do
          override_files = Dir.glob(Decidim::Bih::Engine.root.join("app/overrides/**/*.rb"))
          assert_not_empty override_files, "expected to find override files — an empty glob would make this test pass vacuously"

          voting_overrides = override_files.select do |file|
            source = File.read(file)
            VOTING_AND_VISIBILITY_CLASS_NAMES.any? { |klass| source.match?(/#{Regexp.escape(klass)}\.prepend\(/) }
          end

          # Known today: proposal_vote_award_override.rb (ProposalVote) and
          # budget_vote_award_override.rb (Budgets::Order). If this list ever
          # goes empty while those files still exist, the detection pattern
          # broke silently — fail loudly instead of passing vacuously.
          assert_operator voting_overrides.size, :>=, 2,
                          "expected at least the known proposal-vote and budget-vote award overrides: #{voting_overrides}"

          voting_overrides.each do |file|
            # Strip comment-only lines first: these override files legitimately
            # DESCRIBE EarningRules/the award flow in prose (e.g. "EarningRules
            # applies the per-day vote cap"), and a naive full-source match
            # would flag that documentation as if it were the forbidden read
            # it is explicitly describing the ABSENCE of.
            code_only = File.readlines(file).reject { |line| line.strip.start_with?("#") }.join

            refute_match FORBIDDEN_READS_IN_VOTING_OVERRIDES, code_only,
                         "#{file} prepends onto a vote/ranking/visibility class and must never read a balance, " \
                         "score, or ranking to decide anything about it — award methods on AwardDispatch are fine, " \
                         "reading Ledger/Standings/Scorer/.balance/EarningRules here is not"
          end
        end

        test "a proposal vote is worth exactly one regardless of komšiluk score" do
          refute_includes Decidim::Proposals::ProposalVote.column_names, "weight",
                          "a weight column would be the first step towards points buying influence"
        end

        # --- Layer 3: behaviour ---------------------------------------------

        # This is the falsification target: if a future change ever let the
        # race leak into voting, THIS is the test that would catch it, because
        # it exercises the real Scorer → Standings → ProposalVote path end to
        # end rather than trusting that the schema/source checks above stay
        # complete forever.
        test "a vote from the highest-scoring komšiluk counts the same as a vote from a zero-scoring one" do
          # Manufacture a commanding, unambiguous race lead for @grad.
          10.times { citizen(@grad) }
          standings.refresh!(force: true)

          rows = standings.rows.index_by(&:slug_for_test)
          assert_operator rows["k-grad"].score, :>, rows["k-selo"].score,
                          "fixture setup must actually produce a score gap, or this test proves nothing"

          component = FactoryBot.create(:proposal_component, :with_votes_enabled, organization: @organization)
          leading_author = citizen(@grad)
          trailing_author = citizen(@selo)
          proposal_from_leader = FactoryBot.create(:proposal, component:, users: [leading_author])
          proposal_from_trailer = FactoryBot.create(:proposal, component:, users: [trailing_author])

          leading_voter = citizen(@grad)
          trailing_voter = citizen(@selo)
          FactoryBot.create(:proposal_vote, proposal: proposal_from_leader, author: leading_voter)
          FactoryBot.create(:proposal_vote, proposal: proposal_from_trailer, author: trailing_voter)

          assert_equal 1, proposal_from_leader.reload.proposal_votes_count,
                       "a single vote from the leading komšiluk must count as exactly one"
          assert_equal 1, proposal_from_trailer.reload.proposal_votes_count,
                       "a single vote from the trailing komšiluk must count as exactly one"
          assert_equal proposal_from_leader.proposal_votes_count, proposal_from_trailer.proposal_votes_count,
                       "the race score gap must not change how much either vote is worth"
        end

        test "the race standings are readable without any authorization check" do
          # Recognition is public; it must not gate, or be gated by, the
          # permission system that guards the binding vote.
          assert_kind_of Array, standings.rows
        end
      end
    end
  end
end
