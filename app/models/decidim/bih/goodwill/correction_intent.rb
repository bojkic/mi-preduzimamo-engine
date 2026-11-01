# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # Durable outbox: source moderation commits even if the job queue is down.
      class CorrectionIntent < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_correction_intents"
        belongs_to :report, class_name: "Decidim::Bih::Report"
        belongs_to :report_event, class_name: "Decidim::Bih::ReportEvent"
        after_create_commit :enqueue
        scope :pending, -> { where(processed_at: nil) }
        private
        def enqueue
          SourceCreditCorrectionJob.perform_later(id)
        rescue StandardError => e
          Rails.logger.error("[goodwill] correction outbox enqueue failed: #{e.class}")
        end
      end
    end
  end
end
