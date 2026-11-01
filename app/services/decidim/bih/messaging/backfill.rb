# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The versioned schema migration owns matrix consolidation. This retained
      # read-only task contract lets operators inspect counts without allowing
      # an old import command to overwrite the canonical topic preferences.
      class Backfill
        SOURCE_VERSION = "mi-topic-consolidation-2026-09-15"
        DEFAULT_BATCH_SIZE = 200
        COUNTERS = [:scanned, :planned, :imported, :already_current, :skipped_newer, :invalid, :conflict, :out_of_scope_keys, :suppressions_imported, :unresolved_holds].freeze
        Summary = Struct.new(*COUNTERS, :batches, :cutoff, :source_version, :apply,
                             keyword_init: true) do
          def to_h
            super.transform_values { |value| value.respond_to?(:iso8601) ? value.iso8601 : value }
          end
        end

        def initialize(organization:, apply: false, cutoff: nil, **_options)
          raise ArgumentError, "Matrix backfill is retired; topic consolidation uses the reviewed schema migration" if apply

          @organization = organization
          @cutoff = cutoff || Time.current
        end

        def run!
          users = Decidim::User.where(decidim_organization_id: @organization.id)
          counts = COUNTERS.index_with { |_key| 0 }
          counts[:scanned] = users.count
          counts[:already_current] = Preference.where(organization: @organization).count
          Summary.new(**counts, batches: 0, cutoff: @cutoff, source_version: SOURCE_VERSION,
                                apply: false)
        end

        def summary(*) = run!
      end
    end
  end
end
