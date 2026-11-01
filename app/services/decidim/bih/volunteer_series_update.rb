# frozen_string_literal: true

module Decidim
  module Bih
    # Conservative bulk update/cancel service for recurring volunteer shifts.
    # Only future shifts in the same organization/series are touched. Shifts with
    # logs or confirmed attendance are skipped so operator edits cannot rewrite
    # completed participation or already-reviewed evidence.
    class VolunteerSeriesUpdate
      EDITABLE_ATTRIBUTES = [:title, :meeting_point, :capacity, :category, :requirements].freeze
      Result = Struct.new(:status, :updated_count, :skipped_count, :errors, keyword_init: true)
      Preview = Struct.new(
        :future_count,
        :editable_count,
        :protected_count,
        :going_count,
        :waitlisted_count,
        :logged_hours_count,
        keyword_init: true
      )

      def initialize(organization:, series_key:, actor:, **options)
        @organization = organization
        @series_key = series_key.to_s.strip
        @actor = actor
        @attributes = options.fetch(:attributes, {}).to_h.symbolize_keys.slice(*EDITABLE_ATTRIBUTES)
        @cancel = options.fetch(:cancel, false)
        @cancellation_reason = options[:cancellation_reason].to_s.strip.presence
        @now = options.fetch(:now, Time.current)
      end

      def call
        return result(:invalid, errors: ["series_key_blank"]) if series_key.blank?
        return result(:invalid, errors: ["cancellation_reason_blank"]) if cancel? && cancellation_reason.blank?
        return result(:invalid, errors: ["no_edit_fields"]) unless cancel? || normalized_attributes.present?

        updated = 0
        skipped = 0

        Decidim::Bih::VolunteerOpportunity.transaction do
          series_scope.lock.find_each do |opportunity|
            if protected_shift?(opportunity)
              skipped += 1
              next
            end

            update_shift!(opportunity)
            updated += 1
          end
        end

        result(updated.positive? ? :updated : :no_changes, updated_count: updated, skipped_count: skipped)
      end

      def preview
        shifts = series_scope.includes(:logs, :signups).to_a
        protected_shifts = shifts.select { |opportunity| protected_shift?(opportunity) }
        signups = shifts.flat_map(&:signups)
        Preview.new(
          future_count: shifts.size,
          editable_count: shifts.size - protected_shifts.size,
          protected_count: protected_shifts.size,
          going_count: signups.count(&:going?),
          waitlisted_count: signups.count(&:waitlisted?),
          logged_hours_count: shifts.sum { |opportunity| opportunity.logs.size }
        )
      end

      private

      attr_reader :organization, :series_key, :actor, :attributes, :cancellation_reason, :now

      def cancel?
        @cancel == true
      end

      def series_scope
        Decidim::Bih::VolunteerOpportunity
          .where(organization:, series_key:)
          .where("starts_at IS NULL OR starts_at >= ?", now)
          .order(:series_position, :starts_at, :id)
      end

      def protected_shift?(opportunity)
        opportunity.cancelled? ||
          opportunity.logs.exists? ||
          opportunity.signups.attendance_confirmed.exists?
      end

      def update_shift!(opportunity)
        if cancel?
          opportunity.update!(
            active: false,
            cancelled_at: now,
            canceller: actor,
            cancellation_reason:
          )
        else
          opportunity.update!(normalized_attributes)
        end
      end

      def normalized_attributes
        @normalized_attributes ||= begin
          values = attributes.compact
          values[:title] = values[:title].to_s.strip if values.has_key?(:title)
          values[:meeting_point] = values[:meeting_point].to_s.strip.presence if values.has_key?(:meeting_point)
          values[:requirements] = values[:requirements].to_s.strip.presence if values.has_key?(:requirements)
          values[:capacity] = normalized_capacity(values[:capacity]) if values.has_key?(:capacity)
          values[:category] = normalized_category(values[:category]) if values.has_key?(:category)
          values.compact_blank
        end
      end

      def normalized_capacity(value)
        return nil if value.to_s.strip.blank?

        integer = value.to_i
        integer.positive? ? integer : nil
      end

      def normalized_category(value)
        category = value.to_s.strip
        Decidim::Bih::VolunteeringTaxonomy::CATEGORIES.include?(category) ? category : nil
      end

      def result(status, updated_count: 0, skipped_count: 0, errors: [])
        Result.new(status:, updated_count:, skipped_count:, errors:)
      end
    end
  end
end
