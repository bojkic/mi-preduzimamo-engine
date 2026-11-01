# frozen_string_literal: true

module Decidim
  module Bih
    # Retrieval aids only: proximity and shared address words do not establish
    # that two reports describe the same physical problem.
    class ReportDuplicateCandidates
      LIMIT = 6
      Match = Struct.new(:report, :basis, keyword_init: true)

      def initialize(report)
        @report = report
      end

      def call(query: nil)
        query = query.to_s.strip.first(120)
        return searched(query) if query.present?

        near = DuplicateFinder.new(radius_meters: 150, window_days: 3650).matches(
          organization: @report.organization, latitude: @report.latitude, longitude: @report.longitude, category: @report.category
        ).reject { |report| report.id == @report.id || report.duplicate? }
        address = address_matches
        (near.map { |report| Match.new(report:, basis: "nearby") } + address.map { |report| Match.new(report:, basis: "address") })
          .uniq { |match| match.report.id }.first(LIMIT)
      end

      private

      def base
        Report.where(organization: @report.organization, duplicate_of_report_id: nil).where.not(id: @report.id)
      end

      def searched(query)
        ReportWorkQueue.new(organization: @report.organization).search(base, query).order(created_at: :desc, id: :desc)
                       .limit(LIMIT).map { |report| Match.new(report:, basis: "search") }
      end

      def address_matches
        words = @report.address.to_s.downcase.scan(/\p{L}{3,}|\d{2,}/).without("ulica", "ulici", "bulevar", "trg", "dio", "kod", "broj")
        # Share a bounded prefix so street-name cases such as Vidovdanska / Vidovdanskoj can meet.
        words = words.map { |word| word.length >= 7 ? word.first(6) : word }.uniq.first(4)
        return [] if words.empty?

        clauses = words.map { |_word| "address ILIKE ?" }.join(" OR ")
        values = words.map { |word| "%#{Report.sanitize_sql_like(word)}%" }
        base.where.not(status: Report::TERMINAL_STATUSES).where(clauses, *values).order(created_at: :desc, id: :desc).limit(30)
            .sort_by { |report| [-words.count { |word| report.address.to_s.downcase.include?(word) }, report.category == @report.category ? 0 : 1] }.first(LIMIT)
      end
    end
  end
end
