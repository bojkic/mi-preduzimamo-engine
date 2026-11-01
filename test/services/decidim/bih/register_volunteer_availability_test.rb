# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/register_volunteer_availability"

module Decidim
  module Bih
    class RegisterVolunteerAvailabilityTest < Minitest::Test
      User = Struct.new(:id, keyword_init: true)
      Organization = Struct.new(:id, keyword_init: true)
      Area = Struct.new(:id, keyword_init: true)

      class AvailabilityRecord
        attr_reader :id, :assigned_attributes, :saved

        def initialize(id:, new_record:)
          @id = id
          @new_record = new_record
          @assigned_attributes = {}
          @saved = false
        end

        def new_record?
          @new_record
        end

        def assign_attributes(attributes)
          @assigned_attributes = attributes
        end

        def save!
          @saved = true
        end
      end

      class AvailabilityModel
        class << self
          attr_reader :events, :lookup

          def reset!(record)
            @record = record
            @events = []
            @lookup = nil
          end

          def transaction
            @events << :begin
            yield
          ensure
            @events << :end
          end

          def find_or_initialize_by(organization:, user:)
            @lookup = { organization:, user: }
            @record
          end
        end
      end

      class AwardDispatch
        class << self
          attr_reader :awards

          def reset!
            @awards = []
          end
        end

        def self.volunteer_availability_registered(record, user:)
          awards << { record:, user: }
        end
      end

      def setup
        @user = User.new(id: 5)
        @organization = Organization.new(id: 7)
        @area = Area.new(id: 9)
        AwardDispatch.reset!
      end

      def test_new_availability_is_saved_with_trimmed_fields_and_awarded_once
        record = AvailabilityRecord.new(id: 42, new_record: true)
        AvailabilityModel.reset!(record)

        result = with_collaborators do
          RegisterVolunteerAvailability.call(
            user: @user,
            organization: @organization,
            availability: "  Subotom  ",
            interests: "  Ciscenje parka  ",
            area_scope: "komsiluk",
            local_area: @area,
            day_keys: %w(saturday sunday),
            month_keys: %w(july august),
            time_slot_keys: %w(day afternoon),
            interest_keys: %w(environment),
            skill_keys: %w(field_work),
            capability_keys: %w(outdoor_work)
          )
        end

        assert_equal [:created, record], result
        assert_equal({ organization: @organization, user: @user }, AvailabilityModel.lookup)
        assert_equal(
          {
            area_scope: "komsiluk",
            local_area: @area,
            day_keys: %w(saturday sunday),
            month_keys: %w(july august),
            time_slot_keys: %w(day afternoon),
            interest_keys: %w(environment),
            skill_keys: %w(field_work),
            capability_keys: %w(outdoor_work),
            availability: "Subotom",
            interests: "Ciscenje parka"
          },
          record.assigned_attributes
        )
        assert_equal true, record.saved
        assert_equal [:begin, :end], AvailabilityModel.events
        assert_equal(
          [{ record:, user: @user }],
          AwardDispatch.awards
        )
      end

      def test_existing_availability_is_updated_without_awarding_again
        record = AvailabilityRecord.new(id: 43, new_record: false)
        AvailabilityModel.reset!(record)

        result = with_collaborators do
          RegisterVolunteerAvailability.call(
            user: @user,
            organization: @organization,
            availability: "  Radnim danom  ",
            interests: "  Logistika  "
          )
        end

        assert_equal [:updated, record], result
        assert_equal({ availability: "Radnim danom", interests: "Logistika" }, record.assigned_attributes)
        assert_equal true, record.saved
        assert_empty AwardDispatch.awards
      end

      private

      def with_collaborators(&)
        with_constant(Decidim::Bih, :VolunteerAvailability, AvailabilityModel) do
          ensure_goodwill_namespace do |goodwill|
            with_constant(goodwill, :AwardDispatch, AwardDispatch, &)
          end
        end
      end

      def ensure_goodwill_namespace
        old_defined = Decidim::Bih.const_defined?(:Goodwill, false)
        old_value = Decidim::Bih.const_get(:Goodwill, false) if old_defined
        Decidim::Bih.send(:remove_const, :Goodwill) if old_defined
        goodwill = Module.new
        Decidim::Bih.const_set(:Goodwill, goodwill)
        yield goodwill
      ensure
        Decidim::Bih.send(:remove_const, :Goodwill) if Decidim::Bih.const_defined?(:Goodwill, false)
        Decidim::Bih.const_set(:Goodwill, old_value) if old_defined
      end

      def with_constant(parent, name, value)
        old_defined = parent.const_defined?(name, false)
        old_value = parent.const_get(name, false) if old_defined
        parent.send(:remove_const, name) if old_defined
        parent.const_set(name, value)
        yield
      ensure
        parent.send(:remove_const, name) if parent.const_defined?(name, false)
        parent.const_set(name, old_value) if old_defined
      end
    end
  end
end
