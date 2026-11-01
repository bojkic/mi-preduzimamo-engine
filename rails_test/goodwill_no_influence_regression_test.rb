# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Bodovi zajedništva su ograđeni od obavezujućeg glasa. Ovi testovi
      # postoje da izmjena skale nikad ne pretvori priznanje u uticaj.
      class GoodwillNoInfluenceRegressionTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @rich = FactoryBot.create(:user, :confirmed, organization: @organization)
          @poor = FactoryBot.create(:user, :confirmed, organization: @organization)
          ledger = Decidim::Bih::Goodwill::Ledger.new
          ledger.award(@rich, 5000, reason: "test_seed")
        end

        # SMJER JE SVE. Bodovanje glasanja je dozvoljeno i trazeno (glas = 2 boda,
        # spec tacka 3): bodovi teku IZ glasanja. Zabranjen je obrnuti smjer -
        # da neko CITA bodovni zbir i time odlucuje o glasu, rangu ili vidljivosti.
        # Zato test trazi CITANJA zbira, ne puku koegzistenciju imena.
        SCORE_READS = /contribution_score|cached_contribution|cached_balance|\.balance\b/
        # Nikad i nigdje: bodovi ne smiju odlucivati o glasu ni o vidljivosti sadrzaja.
        FORBIDDEN_SINKS = /vote_weight|weight_for|votes_count\s*=|visible_for|hidden_for|
                           can_participate|moderat/x
        # Sortiranje PO zbiru je dozvoljeno samo unutar same table priznanja -
        # tabla doprinosa i jeste rang doprinosa. Svuda drugdje je zabranjeno.
        ORDER_SINKS = /order\(|reorder\(|ranking/
        RECOGNITION = %r{app/(models|services|controllers|cells|views)/decidim/bih/goodwill/}

        test "no code reads a goodwill score to decide a vote, a ranking or visibility" do
          offenders = Dir.glob("#{Decidim::Bih::Engine.root}/app/**/*.rb").filter_map do |path|
            source = File.read(path)
            next unless source.match?(SCORE_READS)

            bad = source.lines.select do |line|
              next false unless line.match?(SCORE_READS)

              line.match?(FORBIDDEN_SINKS) ||
                (line.match?(ORDER_SINKS) && !path.match?(RECOGNITION))
            end
            [path, bad] if bad.any?
          end

          assert_empty offenders,
                       "bodovni zbir se ne smije citati u odluci o glasu, rangu ili vidljivosti"
        end

        test "the proposal vote override only awards points, never reads a score" do
          source = File.read(
            "#{Decidim::Bih::Engine.root}/app/overrides/decidim/proposal_vote_award_override.rb"
          )

          assert_match(/AwardDispatch|GoodwillAwardJob/, source, "override mora dodjeljivati bodove")
          refute_match(SCORE_READS, source,
                       "override ne smije citati bodovni zbir - to bi bio obrnut smjer")
        end

        test "the levels service is presentation only and never orders anything" do
          source = File.read("#{Decidim::Bih::Engine.root}/app/services/decidim/bih/goodwill/levels.rb")

          refute_match(/order\(|reorder\(|visible|hidden/i, source)
        end

        test "a citizen with 5000 points has the same vote as one with zero" do
          rich_account = Decidim::Bih::Goodwill::Ledger.new.account_for(@rich)
          poor_account = Decidim::Bih::Goodwill::Ledger.new.account_for(@poor)

          assert_equal 5000, rich_account.reload.contribution_score
          assert_equal 0, poor_account.reload.contribution_score

          # Decidim ne poznaje pojam težine glasa vezan za goodwill — nijedan
          # goodwill atribut se ne pojavljuje na modelu glasa.
          vote_columns = Decidim::Proposals::ProposalVote.column_names

          refute(vote_columns.any? { |c| c.match?(/goodwill|contribution|points/i) })
        end

        test "likes and off-platform shares are never awarded for shared-link clicks" do
          schedule = Decidim::Bih::Goodwill::EarningRules::DEFAULT_SCHEDULE

          refute schedule.has_key?(:share)
          refute schedule.has_key?(:share_click)
          refute schedule.has_key?(:shared_link)
        end

        test "recognition levels and thresholds are unchanged" do
          assert_equal(
            [["komsija", 0], ["aktivista", 50], ["predvodnik", 200],
             ["ambasador", 600], ["heroj", 1500]],
            Decidim::Bih::Goodwill::Levels::TABLE.map { |l| [l[:key], l[:threshold]] }
          )
        end

        test "the existing 400 point invitation still deducts and needs manual handling" do
          reward = Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: "pozivnica",
            title: { "sr" => "Pozivnica za događaj zajednice" }, cost: 400
          )

          assert_predicate reward, :deducts_points?
          refute_predicate reward, :auto_issue_at_threshold?
        end
      end
    end
  end
end
