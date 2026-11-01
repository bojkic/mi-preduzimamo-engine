# frozen_string_literal: true

module Decidim
  module Bih
    # Decidim-only operator-to-user message.
    class OperatorMessage < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_operator_messages"

      SUBJECT_MAX = 120
      BODY_MAX = 2_000

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :sender,
                 class_name: "Decidim::User",
                 optional: true

      belongs_to :recipient,
                 class_name: "Decidim::User"

      before_validation :normalize_fields

      validates :subject, presence: true, length: { maximum: SUBJECT_MAX }
      validates :body, presence: true, length: { maximum: BODY_MAX }
      validates :sent_at, presence: true
      validate :users_belong_to_organization

      scope :recent, -> { order(sent_at: :desc, id: :desc) }

      private

      def normalize_fields
        self.subject = subject.to_s.strip
        self.body = body.to_s.strip
        self.sent_at ||= Time.current
      end

      def users_belong_to_organization
        return if organization.blank?

        errors.add(:sender, :invalid) if sender.present? && sender.organization != organization
        errors.add(:recipient, :invalid) if recipient.present? && recipient.organization != organization
      end
    end
  end
end
