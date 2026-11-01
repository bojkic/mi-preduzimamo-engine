# frozen_string_literal: true

require "active_support/time"
require "active_support/core_ext/integer/time"
require "active_support/core_ext/object/blank"
require "securerandom"

module Decidim
  module Bih
    # Parses citizen-entered datetime-local values in the civic program's local
    # timezone and expands a proposal into independently reviewable weekly shifts.
    class VolunteerSchedule
      TIME_ZONE = "Europe/Sarajevo"

      def initialize(starts_at:, ends_at:, signup_deadline_at:, recurrence_count:, maximum:)
        @starts_at = parse(starts_at)
        @ends_at = parse(ends_at)
        @signup_deadline_at = parse(signup_deadline_at)
        @count = normalized_count(recurrence_count, maximum)
      end

      def instances
        key = count > 1 ? SecureRandom.uuid : nil
        Array.new(count) { |index| instance(key, index) }
      end

      private

      attr_reader :starts_at, :ends_at, :signup_deadline_at, :count

      def parse(value)
        return if value.blank?
        return value if value.respond_to?(:advance)

        ActiveSupport::TimeZone[TIME_ZONE].parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def normalized_count(requested, maximum)
        return 1 if starts_at.blank?

        requested.to_i.clamp(1, maximum)
      end

      def instance(key, index)
        attributes = {
          starts_at: shift(starts_at, index),
          ends_at: shift(ends_at, index),
          signup_deadline_at: shift(signup_deadline_at, index)
        }.compact
        return attributes if count == 1

        attributes.merge(series_key: key, series_position: index + 1, series_total: count)
      end

      def shift(value, index)
        value && (value + index.weeks)
      end
    end
  end
end
