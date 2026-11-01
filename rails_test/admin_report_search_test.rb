# frozen_string_literal: true

require_relative "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Full-text search over the admin report queue.
      #
      # The cases here are the ones the operator actually hit: a report filed in
      # Cyrillic that a Latin query has to find, and a report whose only mention
      # of the searched word sits in the CITIZEN'S REPLY rather than in the
      # description — the reason message bodies are part of the index at all.
      #
      # EVERY search assertion is paired with a decoy that must NOT come back.
      # Without the pairing these tests pass against an index that ignores `q`
      # entirely, because an unfiltered queue contains the wanted report too.
      class AdminReportSearchTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        INDEX_PATH = "/admin/bih/reports"
        DECOY = "Rupa na kolovozu u Racanskoj ulici."

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def create_report(description:, organization: @organization, author: @citizen, **attributes)
          Decidim::Bih::Report.create!(
            {
              organization:, author:, description:,
              category: "ostalo", severity: "normalan", status: "primljeno"
            }.merge(attributes)
          )
        end

        def references_in(body) = body.scan(/BR-\d{4}-\d{4}/).uniq

        def search(query)
          sign_in @admin
          get INDEX_PATH, params: { q: query }
          assert_response :success
        end

        # Asserts the search discriminates: +wanted+ is returned and +decoy+,
        # which is in the queue but does not match, is not.
        def assert_finds_only(wanted, decoy)
          assert_includes response.body, wanted.reference,
                          "expected the search to return #{wanted.reference}"
          refute_includes response.body, decoy.reference,
                          "expected the search to exclude the non-matching #{decoy.reference}"
        end

        test "a Latin query finds a report filed in Cyrillic" do
          report = create_report(description: "Угао Улице Први мај, пословни простор бившег Боста.")
          decoy = create_report(description: DECOY)

          search("bosta")

          assert_finds_only(report, decoy)
        end

        test "a Cyrillic query finds a report filed in Latin" do
          report = create_report(description: "Prostor bivseg Bosta u ul Dusana Baranina 29.")
          decoy = create_report(description: DECOY)

          search("Боста")

          assert_finds_only(report, decoy)
        end

        test "a query ignores the diacritics the citizen did or did not type" do
          report = create_report(description: "Puno prljavštine od golubova.")
          decoy = create_report(description: DECOY)

          search("prljavstine")

          assert_finds_only(report, decoy)
        end

        test "a prefix query finds the inflected word" do
          report = create_report(description: "Izblijedila vertikalna signalizacija")
          decoy = create_report(description: DECOY)

          search("signaliz")

          assert_finds_only(report, decoy)
        end

        test "a report is found by a word that appears only in the citizen's reply" do
          report = create_report(description: "Nepropisno parkiranje na trotoaru dostavnih vozila.")
          decoy = create_report(description: DECOY)
          Decidim::Bih::ReportMessage.create!(
            report:, actor: @citizen, actor_role: "citizen", kind: "reply",
            body: "Dostavna vozila vrše dostavu robe za market Bost i parkiraju na trotoaru."
          )

          search("Bost")

          assert_finds_only(report, decoy)
        end

        test "a report is found by an operator's internal note" do
          report = create_report(description: "Nejasna prijava.", internal_note: "Lokacija kod bivseg Bosta.")
          decoy = create_report(description: DECOY)

          search("bosta")

          assert_finds_only(report, decoy)
        end

        test "a report is found by its reference" do
          report = create_report(description: "Bilo šta.")
          decoy = create_report(description: DECOY)

          search(report.reference)

          assert_finds_only(report, decoy)
        end

        test "search combines with the status filter instead of replacing it" do
          received = create_report(description: "Prostor bivšeg Bosta.", status: "primljeno")
          planned = create_report(description: "Drugi prostor bivšeg Bosta.", status: "planirano")

          sign_in @admin
          get INDEX_PATH, params: { q: "bosta", status: "primljeno" }

          assert_response :success
          assert_finds_only(received, planned)
        end

        test "a blank query leaves the queue unfiltered" do
          first = create_report(description: "Prostor bivšeg Bosta.")
          second = create_report(description: DECOY)

          search("   ")

          assert_includes response.body, first.reference
          assert_includes response.body, second.reference
        end

        test "a query that normalises to nothing returns no results rather than everything" do
          report = create_report(description: DECOY)

          search("&&&")

          refute_includes response.body, report.reference
        end

        test "the search index follows an edited description" do
          report = create_report(description: DECOY)
          decoy = create_report(description: "Neka druga prijava bez te rijeci.")
          report.update!(description: "Prostor bivšeg Bosta.")

          search("bosta")

          assert_finds_only(report, decoy)
        end

        test "the search index follows a deleted message" do
          report = create_report(description: "Nepropisno parkiranje na trotoaru.")
          decoy = create_report(description: DECOY)
          message = Decidim::Bih::ReportMessage.create!(
            report:, actor: @citizen, actor_role: "citizen", kind: "reply",
            body: "Radi se o marketu Bost."
          )
          message.destroy!

          search("Bost")

          refute_includes response.body, report.reference
          refute_includes response.body, decoy.reference
        end

        test "search results are scoped to the operator's organization" do
          other_organization = create_organization(host: "druga.example.org")
          foreign_author = FactoryBot.create(:user, :confirmed, organization: other_organization)
          # References are a per-organization sequence, so the first report of
          # each organization is BR-<year>-0001. Two fillers push the foreign
          # report onto a reference of its own — without them this assertion
          # compares two identical strings and fails on a report that was
          # correctly excluded.
          2.times do
            create_report(description: "Popuna.", organization: other_organization, author: foreign_author)
          end
          foreign = create_report(
            description: "Prostor bivšeg Bosta.",
            organization: other_organization, author: foreign_author
          )
          mine = create_report(description: "Prostor bivšeg Bosta u mojoj opstini.")

          refute_equal foreign.reference, mine.reference

          search("bosta")

          assert_includes response.body, mine.reference
          refute_includes response.body, foreign.reference
        end

        test "the queue is paginated instead of truncated at a fixed ceiling" do
          30.times { |i| create_report(description: "Prijava broj #{i}") }

          sign_in @admin
          get INDEX_PATH, params: { page: 1 }
          assert_response :success
          first_page = references_in(response.body)

          get INDEX_PATH, params: { page: 2 }
          assert_response :success
          second_page = references_in(response.body)

          refute_empty second_page, "page 2 must carry the reports page 1 did not"
          assert_empty first_page & second_page, "a report must not appear on both pages"
          assert_equal 30, (first_page | second_page).length
        end
      end
    end
  end
end
