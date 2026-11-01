# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Recognition levels/titles derived purely from a citizen's contribution
      # score (including source corrections). Titles are in the MI "komšija" voice.
      # This is presentation only — it reads the ledger and never writes, so there
      # is no second source of truth to drift (unlike mirroring into Decidim badge
      # scores, which is reset from this contribution figure).
      module Levels
        # Ascending by threshold. Each level unlocks at its contribution score.
        TABLE = [
          { key: "komsija", threshold: 0 },
          { key: "aktivista", threshold: 50 },
          { key: "predvodnik", threshold: 200 },
          { key: "ambasador", threshold: 600 },
          { key: "heroj", threshold: 1500 }
        ].freeze

        # A resolved level for a given score. #title reads i18n lazily so it
        # follows the request locale.
        Level = Struct.new(:key, :threshold, :next_threshold, :score, keyword_init: true) do
          def title
            I18n.t("decidim.bih.goodwill.levels.#{key}")
          end

          def next?
            !next_threshold.nil?
          end

          # Points still needed to reach the next level (nil at the top level).
          def points_to_next
            return nil unless next?

            [next_threshold - score.to_i, 0].max
          end

          # Progress through the current level toward the next, 0–100 (100 at top).
          def progress_percent
            return 100 unless next?

            span = next_threshold - threshold
            return 100 if span <= 0

            (((score.to_i - threshold).to_f / span) * 100).clamp(0, 100).round
          end
        end

        module_function

        # The level for a contribution score.
        def for(score)
          score = score.to_i
          index = TABLE.rindex { |level| score >= level[:threshold] } || 0
          row = TABLE[index]
          nxt = TABLE[index + 1]
          Level.new(key: row[:key], threshold: row[:threshold], next_threshold: nxt&.fetch(:threshold), score:)
        end

        # All level keys, lowest to highest (for docs/admin/tests).
        def keys
          TABLE.map { |level| level[:key] }
        end
      end
    end
  end
end
