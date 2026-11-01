# frozen_string_literal: true

module Decidim
  module Bih
    # Round 25 (W4.2 / W4.4) — a generic, per-organization namespaced key/value
    # store for operator-editable configuration. See the migration for the
    # rationale; the cardinal rule is FALLBACK DISCIPLINE: when this table is
    # empty for an organization, every reader (EarningRules, DepartmentRouting)
    # must behave byte-identically to the pre-table DEFAULTS → config/ENV path.
    #
    # Readers should use the {namespace_for} class helper to load a whole
    # namespace as a plain Hash of { key => value } in one query, then overlay
    # it on top of their existing defaults.
    class Setting < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_settings"

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      validates :namespace, presence: true
      validates :key, presence: true,
                      uniqueness: { scope: [:decidim_organization_id, :namespace], case_sensitive: true }

      scope :in_namespace, ->(namespace) { where(namespace: namespace.to_s) }

      # Loads an entire namespace for an organization as a { "key" => value }
      # Hash. Returns {} when the table is missing/empty so callers fall back to
      # their own defaults. `organization` may be nil (legacy global callers) —
      # that always yields {} (i.e. defaults/ENV only).
      def self.namespace_for(organization, namespace)
        return {} if organization.blank?
        return {} unless table_available?

        in_namespace(namespace)
          .where(decidim_organization_id: organization.id)
          .pluck(:key, :value)
          .to_h
      rescue StandardError
        # Never let a settings read take down a points award or a forward.
        {}
      end

      # Upserts a single (organization, namespace, key) value. A nil/blank value
      # DELETES the row, so "clear this override" restores the default. Returns
      # the value written (or nil when cleared).
      def self.put(organization, namespace, key, value)
        attempts = 0
        begin
          record = find_or_initialize_by(
            organization:, namespace: namespace.to_s, key: key.to_s
          )
          if value.nil? || (value.respond_to?(:blank?) && value.blank? && value != false && value != 0)
            record.destroy if record.persisted?
            return nil
          end

          record.value = value
          record.save!
          value
        rescue ActiveRecord::RecordNotUnique
          # A concurrent writer committed the row between our miss and our INSERT.
          # Re-run once: find_or_initialize_by now finds the committed row, so the
          # second pass is an UPDATE that applies our value on top of it.
          attempts += 1
          raise if attempts > 1

          retry
        end
      end

      # Guards against querying the table before its migration has run (e.g.
      # during boot on a not-yet-migrated DB).
      def self.table_available?
        table_exists?
      rescue StandardError
        false
      end
    end
  end
end
