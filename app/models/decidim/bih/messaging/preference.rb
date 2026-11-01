# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # What a citizen currently wants, per topic across delivery channels.
      #
      # An explicit `blocked` is a STORED VALUE, not an absent row: "we never
      # asked" and "they said no" are different facts and the consolidation is
      # not allowed to lose the difference. `source` records how the value came
      # to be, and `organization_default` is a first-class source precisely so
      # that a tenant policy can never be mistaken for somebody's click.
      class Preference < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_messaging_preferences"

        TOPICS = TopicPreferences::TOPICS
        STATES = %w(allowed blocked).freeze
        SOURCES = %w(account provider_opt_out organization_default legacy_import unknown).freeze
        # The only source that is evidence of a person deciding something.
        PERSONAL_SOURCES = %w(account).freeze

        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        belongs_to :user, class_name: "Decidim::User", foreign_key: :decidim_user_id

        validates :topic, inclusion: { in: TOPICS }
        validates :state, inclusion: { in: STATES }
        validates :source, inclusion: { in: SOURCES }
        validates :policy_version, :change_id, :changed_at, presence: true
        validates :decidim_user_id, uniqueness: { scope: [:decidim_organization_id, :topic] }
        validate :user_belongs_to_organization

        scope :allowed, -> { where(state: "allowed") }
        scope :blocked, -> { where(state: "blocked") }

        def allowed?
          state == "allowed"
        end

        def blocked?
          state == "blocked"
        end

        # A stored `true` is not automatically somebody's decision. Callers that
        # want to say "the citizen chose this" must ask this, not the value.
        def personal_choice?
          PERSONAL_SOURCES.include?(source)
        end

        private

        def user_belongs_to_organization
          return if user.nil? || organization.nil?
          return if user.decidim_organization_id == organization.id

          errors.add(:user, :invalid)
        end
      end
    end
  end
end
