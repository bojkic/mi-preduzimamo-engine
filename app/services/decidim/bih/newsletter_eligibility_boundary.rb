# frozen_string_literal: true

module Decidim
  module Bih
    # The half of {NewsletterEligibility} that is answerable WITHOUT Rails, so
    # the D12 boundary can be asserted by the pure suite rather than described.
    #
    # It exists because the question "can this audience ever be a donor cohort"
    # must have an executable answer that does not need a database, a schema or
    # a booted application to obtain.
    module NewsletterEligibilityBoundary
      module_function

      # Owner decision D12. There is no donor selector in the newsletter
      # audience, and there is no MI store of donor communication preferences
      # to build one from: the Odoo mirror this platform holds is an aggregate
      # of donation TOTALS, never a list of people.
      def donor_cohort_selectable? = false

      # What the newsletter audience IS selected by - platform citizenship
      # facts only. A reviewer can compare this list against the query.
      SELECTORS = %w(
        organization
        account_available
        confirmed
        newsletter_notifications_at
        email_present
        transport_suppression
        proven_current_address
      ).freeze

      # ---- the scanner both suites use ---------------------------------
      #
      # D12 has to hold across BOTH repos, so the rule lives here once rather
      # than being re-derived in an engine test and a host test with two
      # slightly different regexes.

      # What a donor-only cohort would be selected BY.
      DONOR_CONCEPTS = %w(donor donors fundraising giving_level supporter_tier donor_segment).freeze

      # What a communication preference looks like in this codebase.
      COMMUNICATION_CONCEPTS = %w(newsletter mailing_list unsubscribe notification_preference opt_in opt_out).freeze

      # A donor communication preference is a COLUMN or a CHAINED QUERY, not a
      # file that happens to mention both subjects hundreds of lines apart.
      # Two consecutive lines is wide enough for `where(donor: true)` followed
      # by `.where.not(newsletter_notifications_at: nil)`, and narrow enough to
      # mean something.
      WINDOW = 2

      # `\b` does NOT break on an underscore, so /\bdonor\b/ misses
      # `donor_newsletter_opt_in` - precisely the column this rule forbids.
      def token(word)
        /(?<![A-Za-z])#{word}(?![A-Za-z])/i
      end

      # Comments are not code. D12 has to be EXPLAINED somewhere, and a scan
      # that counted the explanation as a violation would force the rule to go
      # undocumented in order to stay enforced.
      def executable_lines(source)
        source.lines.reject { |line| line.strip.start_with?("#") }
      end

      # @return [Array<String>] the offending windows, empty when clean
      def offending_windows(source)
        lines = executable_lines(source)
        # Windows of AT MOST {WINDOW} lines starting at every line, so a single
        # line is itself a window. `each_cons(2)` silently yields nothing for a
        # one-line input, which would make a column declared on its own line
        # invisible.
        (0...lines.size).filter_map do |index|
          chunk = lines[index, WINDOW].join
          next unless DONOR_CONCEPTS.any? { |concept| chunk.match?(token(concept)) }
          next unless COMMUNICATION_CONCEPTS.any? { |concept| chunk.match?(token(concept)) }

          chunk
        end
      end

      # @param paths [Array<String>] Ruby sources to scan
      # @return [Array<String>] "path: line" for each violation
      def scan(paths)
        Array(paths).flat_map do |path|
          offending_windows(File.read(path)).map { |chunk| "#{path}: #{chunk.strip}" }
        end
      end
    end
  end
end
