# frozen_string_literal: true

module Decidim
  module Bih
    module Race
      # Owns the cached standings table: refreshing it, freezing it, and reading
      # it back for the public page.
      #
      # The public leaderboard NEVER calls Scorer. It calls #rows, which is a
      # single indexed SELECT. That is what keeps launch night from taking the
      # rest of the platform down.
      class Standings
        # The published rule is "osvježava se najviše na 10 minuta".
        REFRESH_INTERVAL = 10.minutes

        def initialize(organization, config: nil)
          @organization = organization
          @config = config || Config.new(organization:)
        end

        def final?
          Edition.for(organization)&.finalized_at.present? || Standing.exists?(organization:, edition_key: Edition::KEY, final: true)
        end

        def computed_at
          scope.maximum(:computed_at)
        end

        # Recomputes and rewrites the live standing. Returns the number of rows
        # written, or 0 when the interval guard (or a freeze) suppressed the run.
        #
        # The edition row lock serializes writers; the UTC bucket allows one
        # scheduled refresh per ten-minute slot without stretching to twenty
        # minutes when task boot adds a few seconds. Force skips only the slot.
        def refresh!(force: false)
          ed = Edition.ensure_for!(organization)
          ed.with_lock do
            return 0 if final?
            return 0 if !force && recently_computed?
            computed = if config.finished?
                         return 0 unless ed.captured_at
                         Review.new(organization).preview
                       else
                         Scorer.new(organization:, config:).rows
                       end
            write_snapshot!(computed, final: false)
          end
        end

        # Finalization requires an authenticated reviewer and the reviewed
        # immutable capture. The deadline task only captures facts.
        def freeze!(actor: nil, reason: nil, expected_digest: nil, expected_revision: nil)
          Review.new(organization).finalize!(actor:, reason:, expected_digest:, expected_revision:)
        end

        def rows(zone: nil)
          relation = scope
          relation = relation.in_zone(zone) if zone.present?
          relation = zone.present? ? relation.order(:rank_in_zone) : relation.ranked
          relation.includes(:komsiluk).to_a
        end

        def leader(zone)
          ed = Edition.for(organization)
          choice = ed&.finalized_at && ed.settings.fetch("winners", {})[zone]
          return nil if choice == "none"
          row = choice.present? ? scope.find_by(komsiluk_id: choice) : scope.in_zone(zone).order(:rank_in_zone).includes(:komsiluk).first
          row if row&.score.to_i.positive?
        end

        def for_komsiluk(komsiluk_id)
          return nil if komsiluk_id.blank?

          scope.includes(:komsiluk).find_by(komsiluk_id:)
        end

        private

        attr_reader :organization, :config

        # Reads the frozen snapshot once it exists, the live table before that.
        def scope
          Standing.where(organization:, edition_key: Edition::KEY, final: final?)
        end

        # Bucket boundary, not elapsed wall time since the previous task.
        def recently_computed?
          last = computed_at
          last.present? && last.to_i / REFRESH_INTERVAL.to_i == Time.current.to_i / REFRESH_INTERVAL.to_i
        end

        public

        # Caller owns the edition lock. Final rows are insert-only.
        def write_snapshot!(computed, final:)
          now = Time.current
          zone_positions = Hash.new(0)

          records = computed.each_with_index.map do |row, index|
            zone = row[:zona].presence
            zone_positions[zone] += 1

            {
              decidim_organization_id: organization.id,
              edition_key: Edition::KEY,
              komsiluk_id: row[:komsiluk_id],
              zona: zone,
              registered: row[:registered],
              reports: row[:reports],
              proposals: row[:proposals],
              score: row[:score],
              reached_at: row[:reached_at],
              rank_overall: index + 1,
              rank_in_zone: zone_positions[zone],
              computed_at: now,
              final:,
              created_at: now,
              updated_at: now
            }
          end

          Standing.transaction do
            if final
              raise Review::Invalid, "final snapshot exists" if Standing.exists?(organization:, edition_key: Edition::KEY, final: true)
            else
              Standing.where(organization:, edition_key: Edition::KEY, final: false).delete_all
            end
            # Every hash here is built from Scorer's already-validated, already-typed
            # SQL output — there is nothing left for AR validations to check, and a
            # per-row INSERT for up to ~92 komšiluci would defeat the point of a
            # single cached-table write on launch night.
            # rubocop:disable Rails/SkipsModelValidations
            Standing.insert_all!(records) if records.any?
            # rubocop:enable Rails/SkipsModelValidations
          end

          records.size
        end
      end
    end
  end
end
