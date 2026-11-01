# frozen_string_literal: true

module Decidim
  module Bih
    # Private per-citizen Komšiluk assignment record.
    #
    # PRIVACY CONTRACT (enforced by design, not just convention):
    #   - The public Decidim profile may render ONLY the translated komšiluk
    #     name ("Komšija iz ...") when the citizen allows public recognition.
    #     It must never expose MZ, source, assignment timestamp, coordinates or
    #     address-derived data.
    #   - NEVER write any field from this record to Decidim::User#extended_data.
    #   - NEVER expose it in the Decidim admin user-show page.
    #   - The citizen's address is NEVER stored here; only the resolved komsiluk_id
    #     and mz_id (both point-resolved or from primary_mz_slug for dropdown).
    #
    # MZ resolution (decoupled model):
    #   - Map-click / address-suggest: mz is resolved INDEPENDENTLY by
    #     point-in-polygon on the MZ polygon set — NOT derived from komsiluk.parent.
    #   - Dropdown: no point available; mz falls back to komsiluk.primary_mz
    #     (the computed soft pointer stored as primary_mz_slug).
    #
    # The record is lazy-created on the citizen's first komšiluk selection, mirroring
    # the Goodwill::Account "find-or-create" pattern.
    #
    # The `decidim_user_id` FK has `on_delete: :nullify` so deleting a Decidim user
    # never cascades through to this table. Nullable komsiluk_id/mz_id survive the
    # nullification gracefully.
    class CitizenProfile < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_citizen_profiles"

      SOURCES = %w(map address dropdown postal registration).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      belongs_to :user,
                 class_name: "Decidim::User",
                 foreign_key: "decidim_user_id",
                 optional: true

      belongs_to :komsiluk,
                 class_name: "Decidim::Bih::LocalArea",
                 optional: true

      belongs_to :mz,
                 class_name: "Decidim::Bih::LocalArea",
                 optional: true

      around_save :track_race_assignment

      validates :source, allow_nil: true, inclusion: { in: SOURCES }

      # Find the profile for this user+org, creating a bare row if absent.
      # The caller must call #assign_komsiluk! to populate it meaningfully.
      def self.for_user(user, organization:)
        find_or_create_by!(
          decidim_organization_id: organization.id,
          decidim_user_id: user.id
        ) do |profile|
          profile.organization = organization
        end
      end

      # Idempotent assignment: updates komsiluk + mz + source + timestamp.
      #
      # `mz` is accepted as an explicit parameter (point-resolved by the caller)
      # rather than derived from komsiluk.parent — the decoupled model means
      # there is no guaranteed parent link.
      #
      # When `mz` is nil (e.g. dropdown picker with no point), falls back to
      # komsiluk.primary_mz (the computed soft pointer). If that is also nil,
      # mz_id is stored as nil.
      #
      # Same-area confirmation preserves first assignment/qualification time.
      def assign_komsiluk!(komsiluk, source:, resolved_mz: nil)
        raise ArgumentError, "komsiluk must be kind=komsiluk" unless komsiluk.kind == "komsiluk" && komsiluk.decidim_organization_id == decidim_organization_id

        effective_mz = resolved_mz || komsiluk.primary_mz

        update!(
          komsiluk:,
          mz: effective_mz,
          mz_id: effective_mz&.id,
          source: source.to_s,
          assigned_at: komsiluk_id == komsiluk.id && assigned_at ? assigned_at : Time.current
        )
      end

      # Whether this citizen has ever selected a komšiluk.
      def track_race_assignment(&block)
        Decidim::Bih::Race::MembershipTracker.track(self, &block)
      end

      def assigned?
        komsiluk_id.present?
      end
    end
  end
end
