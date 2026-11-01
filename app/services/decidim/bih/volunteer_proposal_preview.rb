# frozen_string_literal: true

require "digest"
require "json"

module Decidim
  module Bih
    # Builds the exact schedule the author must inspect before first submission.
    # Duration is shown twice when a DST change makes elapsed and Sarajevo wall
    # time differ. Overlap is a warning: a real programme may deliberately overlap.
    class VolunteerProposalPreview
      TIME_ZONE = "Europe/Sarajevo"
      LONG_TERM_HOURS = 24
      Term = Struct.new(:number, :starts_at, :ends_at, :signup_deadline_at,
                        :elapsed_hours, :local_hours, keyword_init: true)
      Result = Struct.new(:terms, :overlaps, :long_terms, keyword_init: true)

      def self.build(starts_at:, ends_at:, signup_deadline_at:, recurrence_count:, maximum:)
        generated = VolunteerSchedule.new(starts_at:, ends_at:, signup_deadline_at:,
                                          recurrence_count:, maximum:).instances
        terms = generated.each_with_index.map do |values, index|
          starts = values[:starts_at]
          ends = values[:ends_at]
          elapsed = (ends - starts) / 1.hour if starts && ends
          local = elapsed + (ends.in_time_zone(TIME_ZONE).utc_offset - starts.in_time_zone(TIME_ZONE).utc_offset) / 3600.0 if elapsed
          Term.new(number: index + 1, starts_at: starts, ends_at: ends,
                   signup_deadline_at: values[:signup_deadline_at],
                   elapsed_hours: elapsed, local_hours: local)
        end
        overlaps = terms.combination(2).filter_map do |left, right|
          next unless left.starts_at && left.ends_at && right.starts_at && right.ends_at
          next unless left.starts_at < right.ends_at && right.starts_at < left.ends_at

          [left.number, right.number]
        end
        Result.new(terms:, overlaps:, long_terms: terms.select { |term| term.local_hours && term.local_hours > LONG_TERM_HOURS })
      end

      # A canonical digest binds the preview to every permitted submitted field,
      # including ordered multi-select values and empty controls.
      def self.digest(payload)
        Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))
      end

      def self.canonical(value)
        case value
        when Hash
          value.to_h.sort_by { |key, _| key.to_s }.to_h { |key, nested| [key.to_s, canonical(nested)] }
        when Array
          value.map { |nested| canonical(nested) }
        else
          value.to_s
        end
      end
      private_class_method :canonical
    end
  end
end
