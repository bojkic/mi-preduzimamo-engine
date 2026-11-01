# frozen_string_literal: true

module Decidim
  module Bih
    module Privacy
      # Durable, PII-free audit row for an explicit privacy retention sweep.
      #
      # It records aggregate counts, cutoffs, status and sanitized failure
      # details only. Never store report descriptions, contacts, Viber sender
      # identifiers, volunteer free text, raw logs or SQL here.
      class RetentionRun < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_privacy_retention_runs"

        STATUSES = %w(running ok fail).freeze
        MAX_ERROR_LENGTH = 500

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        validates :status, inclusion: { in: STATUSES }
        validates :source, presence: true, length: { maximum: 64 }
        validates :started_at, presence: true
        validates :total, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        validate :finished_at_after_started_at

        scope :recent, -> { order(started_at: :desc, id: :desc) }

        def live?
          !dry_run?
        end

        def finish!(counts:)
          safe_counts = normalize_counts(counts)
          update!(
            status: "ok",
            finished_at: Time.current,
            counts: safe_counts,
            total: safe_counts.values.sum,
            error_class: nil,
            error_message: nil
          )
        end

        def fail!(error)
          update!(
            status: "fail",
            finished_at: Time.current,
            error_class: sanitize_error_class(error),
            error_message: sanitize_error_message(error)
          )
        end

        private

        def normalize_counts(raw_counts)
          raw_counts.to_h.transform_keys(&:to_s).transform_values(&:to_i)
        end

        def sanitize_error_class(error)
          error.class.name.to_s[0, 120]
        end

        def sanitize_error_message(error)
          text = if defined?(Decidim::Bih::SafeErrorMetadata)
                   Decidim::Bih::SafeErrorMetadata.sanitize_text(error.message, max: MAX_ERROR_LENGTH)
                 else
                   error.message.to_s.split.join(" ")[0, MAX_ERROR_LENGTH]
                 end
          text.presence
        end

        def finished_at_after_started_at
          return if finished_at.blank? || started_at.blank?
          return if finished_at >= started_at

          errors.add(:finished_at, :invalid)
        end
      end
    end
  end
end
