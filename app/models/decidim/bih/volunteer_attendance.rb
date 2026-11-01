# frozen_string_literal: true

module Decidim
  module Bih
    # An explicit decision about a person's presence on one Sarajevo work date.
    # Legacy signup-level timestamps remain historical and are not copied here.
    class VolunteerAttendance < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_volunteer_attendances"

      STATUSES = %w(confirmed absent).freeze
      SOURCES = %w(operator qr).freeze

      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: "decidim_organization_id"
      belongs_to :opportunity, class_name: "Decidim::Bih::VolunteerOpportunity",
                               foreign_key: "decidim_bih_volunteer_opportunity_id"
      belongs_to :signup, class_name: "Decidim::Bih::VolunteerSignup",
                          foreign_key: "decidim_bih_volunteer_signup_id", inverse_of: :dated_attendances
      belongs_to :user, class_name: "Decidim::User", foreign_key: "decidim_user_id"
      belongs_to :confirmer, class_name: "Decidim::User", foreign_key: "confirmed_by_id"

      validates :work_date, :confirmed_at, presence: true
      validates :status, inclusion: { in: STATUSES }
      validates :source, inclusion: { in: SOURCES }
      validate :same_signup_scope

      scope :confirmed, -> { where(status: "confirmed") }

      def confirmed?
        status == "confirmed"
      end

      private

      def same_signup_scope
        return unless signup

        errors.add(:signup, :invalid) unless signup.decidim_organization_id == decidim_organization_id &&
                                             signup.decidim_bih_volunteer_opportunity_id == decidim_bih_volunteer_opportunity_id &&
                                             signup.decidim_user_id == decidim_user_id
      end
    end
  end
end
