# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/messaging/message_class"
require_relative "../../../../app/services/decidim/bih/newsletter_eligibility_boundary"

module Decidim
  module Bih
    # Owner decision D12, made executable.
    #
    #   MI's newsletter carries PLATFORM NEWS to CITIZENS.
    #   Odoo carries DONATIONS, DONORS and FUNDRAISING CAMPAIGNS.
    #
    # The split is by audience and purpose, and "enforced in code, not merely
    # documented" means these two things have to be false forever:
    #
    #   * the newsletter audience query can select a donor-only cohort
    #   * MI records a donor communication preference
    #
    # Neither can be proved by reading a doc, so both are scanned here. This is
    # a pure test: it reads source and the registry, never a database.
    class NewsletterBoundaryTest < Minitest::Test
      ENGINE_ROOT = File.expand_path("../../../..", __dir__)

      DONOR_CONCEPTS = NewsletterEligibilityBoundary::DONOR_CONCEPTS

      def ruby_sources(*globs)
        globs.flat_map { |glob| Dir[File.join(ENGINE_ROOT, glob)] }.reject { |path| path.include?("/test/") }
      end

      # Comments are not code. D12 itself has to be EXPLAINED somewhere, and a
      # scan that counts the explanation as a violation would force the rule to
      # go undocumented in order to stay enforced.
      def code_in(path)
        NewsletterEligibilityBoundary.executable_lines(File.read(path)).join
      end

      def eligibility_path
        File.join(ENGINE_ROOT, "app/services/decidim/bih/newsletter_eligibility.rb")
      end

      def eligibility_source = File.read(eligibility_path)

      def eligibility_code = code_in(eligibility_path)

      # ---- the audience cannot be a donor cohort ------------------------

      def test_the_newsletter_audience_names_no_donor_concept_in_its_query
        # The constant that LISTS the forbidden words is allowed to contain
        # them; the executable query must not.
        query_body = eligibility_code.split("module_function").last.to_s
        DONOR_CONCEPTS.each do |concept|
          refute_match(token(concept), query_body,
                       "the newsletter audience query must not be able to reach a #{concept} concept")
        end
      end

      def test_the_module_says_so_answerably_rather_than_in_a_comment
        refute NewsletterEligibilityBoundary.donor_cohort_selectable?
      end

      # ---- MI records no donor communication preference ------------------

      # The one that would actually break D12: a table, column or query that
      # joins a donor identity to a mailing choice. MI holds an Odoo mirror of
      # donation TOTALS - an aggregate - and that is the whole of it.
      def test_no_engine_source_combines_a_donor_concept_with_a_communication_preference
        offenders = ruby_sources("app/**/*.rb", "lib/**/*.rb").flat_map do |path|
          next [] if path.end_with?("newsletter_eligibility.rb") # declares the forbidden list

          offending_windows(File.read(path)).map { |line| "#{path.sub("#{ENGINE_ROOT}/", "")}: #{line.strip}" }
        end

        assert_empty offenders,
                     "no MI code may record or select a donor communication preference; Odoo owns that audience"
      end

      def offending_windows(code) = NewsletterEligibilityBoundary.offending_windows(code)

      def token(word) = NewsletterEligibilityBoundary.token(word)

      # A scan that cannot fail is not a guard. This feeds it exactly the
      # shape it exists to catch.
      def test_the_donor_preference_scan_catches_what_it_claims_to
        column = "t.boolean :donor_newsletter_opt_in\n"
        chained = "scope = scope.where(donor: true)\nscope.where.not(newsletter_notifications_at: nil)\n"

        refute_empty offending_windows(column), "a donor newsletter column must be caught"
        refute_empty offending_windows(chained), "a donor cohort chained onto a newsletter query must be caught"
        assert_empty offending_windows("puts :donor\n\n\n\n\n\nputs :newsletter\n"),
                     "two unrelated mentions far apart are not a violation"
      end

      # ---- the registry already names the boundary ----------------------

      def test_odoo_campaigns_are_declared_an_external_boundary
        boundary = Messaging::MessageClass::EXTERNAL_BOUNDARIES.find { |row| row[:key] == "boundary.odoo_campaigns" }
        assert boundary, "boundary.odoo_campaigns must stay declared: Odoo audiences are administered outside MI"
        assert_match(/outside MI/i, boundary[:reason])
      end

      # P1-P11 stay with MI. They are campaign classes in MI's own registry,
      # and moving one to Odoo would mean deleting it from here.
      def test_the_launch_campaign_classes_stay_in_mis_registry
        %w(campaign.transactional_phone campaign.marketing_phone campaign.letter_p11).each do |key|
          entry = Messaging::MessageClass.fetch(key)
          assert entry, "#{key} must stay an MI message class"
          refute_empty entry.message_keys, "#{key} must still own its P-numbered messages"
        end

        owned = %w(campaign.transactional_phone campaign.marketing_phone campaign.letter_p11)
                .flat_map { |key| Messaging::MessageClass.fetch(key).message_keys }
        # P2 and P6 were retired with the 72-hour sweep and do not exist.
        assert_equal %w(P1 P3 P4 P5 P7 P8 P9 P10 P11).sort, owned.sort
        refute_includes owned, "P2"
        refute_includes owned, "P6"
      end

      def test_proven_address_and_topic_are_required_independently_of_the_retired_switch
        body = eligibility_code[/def narrow.*?\n      end/m].to_s
        assert_includes body, "proven_address_ids"
        assert_includes body, 'topic: "platform_news", state: "blocked"'
        refute_includes body, "verified_audience?"
      end

      def test_suppression_is_applied_before_address_and_topic_checks
        body = eligibility_code[/def narrow.*?\n      end/m].to_s
        assert_match(/exclude_suppressed/, body)
        assert_operator body.index("exclude_suppressed"), :<, body.index("proven_address_ids")
      end
    end
  end
end
