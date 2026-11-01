# frozen_string_literal: true

module Decidim
  module Bih
    # A durable, encrypted snapshot approved by a person. Sending is never retried
    # automatically after an uncertain provider outcome.
    class ReportDispatch < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_dispatches"
      self.filter_attributes += [:snapshot_ciphertext, :reconciliation_evidence]
      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :approved_by, class_name: "Decidim::User"
      belongs_to :reconciled_by, class_name: "Decidim::User", optional: true
      STATES = %w(queued sending accepted unknown cancelled not_sent).freeze
      validates :state, inclusion: { in: STATES }
      validates :kind, inclusion: { in: %w(initial supplement followup) }
      validates :input_digest, :deduplication_key, :message_id, :snapshot_ciphertext, presence: true
      validate :same_organization
      before_update :protect_snapshot

      def snapshot
        return {} if data_redacted_at

        Infobip::EncryptedJobEnvelope.open(snapshot_ciphertext, purpose: "report-dispatch", salt: "bih-report-dispatch-v1")
      end

      def snapshot=(value)
        self.snapshot_ciphertext = Infobip::EncryptedJobEnvelope.seal(value, purpose: "report-dispatch", salt: "bih-report-dispatch-v1")
      end

      private

      def same_organization
        [approved_by, reconciled_by].compact.each do |actor|
          errors.add(:approved_by, :invalid) if actor.organization != report&.organization
        end
      end

      def protect_snapshot
        if %w(report_id approved_by_id kind input_digest deduplication_key snapshot_ciphertext message_id data_redacted_at).any? { |key| will_save_change_to_attribute?(key) }
          errors.add(:base, "Approved snapshot is immutable")
          throw :abort
        end
      end
    end
  end
end
