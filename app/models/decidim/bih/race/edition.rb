# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Race
      class Edition < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_race_editions"
        KEY = "2026"
        belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
        has_many :memberships, class_name: "Decidim::Bih::Race::Membership", dependent: :restrict_with_exception
        has_many :events, class_name: "Decidim::Bih::Race::Event", dependent: :restrict_with_exception
        validates :key, presence: true, uniqueness: { scope: :decidim_organization_id }
        validate :immutable_capture

        def self.for(organization)
          find_by(organization:, key: KEY)
        end

        def self.ensure_for!(organization)
          find_by(organization:, key: KEY) || create_or_find_by!(organization:, key: KEY)
        rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
          # The uniqueness validator can win a concurrent first-create race
          # before the unique index does; reload the committed edition.
          find_by!(organization:, key: KEY)
        end

        def record!(kind, actor: nil, item_key: nil, **data)
          events.create!(kind:, actor_id: actor&.id, item_key:, data:)
        end

        def self.digest(value)
          Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
        end

        def self.canonical(value)
          case value
          when Hash then value.stringify_keys.sort.to_h.transform_values { |v| canonical(v) }
          when Array then value.map { |v| canonical(v) }
          else value.respond_to?(:as_json) ? value.as_json : value
          end
        end

        private

        def immutable_capture
          if captured_at_in_database && (will_save_change_to_snapshot? || will_save_change_to_snapshot_digest? || will_save_change_to_captured_at?)
            errors.add(:snapshot, "is immutable")
          end
          errors.add(:finalized_at, "is immutable") if finalized_at_in_database && will_save_change_to_finalized_at?
        end
      end
    end
  end
end
