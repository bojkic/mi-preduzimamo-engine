# frozen_string_literal: true

module Decidim
  module Bih
    # Records a citizen's general willingness/availability to volunteer and
    # awards the one-time volunteer_availability goodwill points on first
    # registration. Later edits update the record but do not mint more points.
    class RegisterVolunteerAvailability
      def self.call(user:, organization:, availability:, interests:, **structured_attributes)
        new(user:, organization:, availability:, interests:, **structured_attributes).call
      end

      def initialize(user:, organization:, availability:, interests:, **structured_attributes)
        @user = user
        @organization = organization
        @availability = availability.to_s.strip
        @interests = interests.to_s.strip
        @structured_attributes = structured_attributes
      end

      def call
        record = nil
        created = false

        VolunteerAvailability.transaction do
          record = VolunteerAvailability.find_or_initialize_by(organization:, user:)
          created = record.new_record?
          record.assign_attributes(structured_attributes.merge(availability:, interests:))
          record.save!

          award(record) if created
        end

        [created ? :created : :updated, record]
      end

      private

      attr_reader :user, :organization, :availability, :interests, :structured_attributes

      def award(record)
        Decidim::Bih::Goodwill::AwardDispatch.volunteer_availability_registered(record, user:)
      end
    end
  end
end
