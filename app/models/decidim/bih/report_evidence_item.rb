# frozen_string_literal: true

module Decidim
  module Bih
    class ReportEvidenceItem < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_evidence_items"
      self.filter_attributes += [:purge_descriptor_ciphertext]
      SOURCES = %w(original citizen_message service_mail).freeze
      SENSITIVE_FLAGS = %w(face_visible plate_visible document_personal_data).freeze
      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :blob, class_name: "ActiveStorage::Blob", optional: true
      has_one_attached :private_file, service: ->(_record) { ReportPrivateStorage.service_name }
      scope :live, -> { where(purged_at: nil) }
      validate :private_blob_identity
      before_update :protect_tombstone_identity

      def purged? = purged_at.present?

      def private_blob_identity
        if purged?
          errors.add(:blob, :invalid) if blob_id.present?
        elsif !blob || !ReportPrivateStorage.private?(blob) || blob.checksum != checksum
          errors.add(:blob, :invalid)
        end
      end
      has_many :dispatch_evidence, class_name: "Decidim::Bih::ReportDispatchEvidence", foreign_key: :evidence_item_id, dependent: :restrict_with_exception
      validates :source, inclusion: { in: SOURCES }
      validates :checksum, :content_type, presence: true
      validates :byte_size, numericality: { greater_than: 0 }
      validate { errors.add(:sensitive_flags, :invalid) unless (sensitive_flags - SENSITIVE_FLAGS).empty? }
      def protect_tombstone_identity
        return unless purged_at_in_database

        fields = %w(report_id blob_id checksum source source_id source_blob_id content_type byte_size purged_at)
        return unless fields.any? { |field| will_save_change_to_attribute?(field) }

        errors.add(:base, "Purged evidence identity is immutable")
        throw :abort
      end

      def assessment_verified?
        !purged? && assessment["format"] == Ai::EvidenceAssessment::FORMAT &&
          Ai::EvidenceAssessment.valid_result?(assessment.slice(*Ai::EvidenceAssessment::SCHEMA[:required]), request_count: assessment["request_count"])
      end

      def automatic_handoff?
        owned_private_blob? && assessment_verified? && sensitive_flags.empty? && assessment["state"] == "suitable" &&
          assessment["sensitive_presence"].values.all? { |value| value == "absent" } &&
          !assessment["observation_codes"].intersect?(Ai::EvidenceAssessment::SENSITIVE_CODES.keys)
      end

      def assessment_for_context
        return { "state" => "uncertain", "reason" => "assessment_format_unverified" } unless assessment_verified?

        observations = assessment.fetch("observation_codes").map { |code| Ai::EvidenceAssessment::OBSERVATIONS.fetch(code) }
        assessment.slice("format", "state", "observation_codes", "sensitive_presence", "sensitive_flags", "request_matches", "reason").merge("observations" => observations)
      end

      # Serialize before copying: duplicate/concurrent sync never uploads an
      # orphan. Tombstones bind the exact old source, not later identical bytes.
      def self.register!(report:, blob:, source:, source_id: nil)
        report.with_lock do
          origin_id = ReportPrivateStorage.stable_source_blob_id(blob)
          existing = live.find_by(report:, checksum: blob.checksum)
          next existing.ensure_private! if existing
          next if where(report:, source:, source_id:, source_blob_id: origin_id).where.not(purged_at: nil).exists?

          private_blob = ReportPrivateStorage.copy_private!(blob)
          copied = private_blob.id != blob.id
          ActiveRecord::Base.current_transaction.after_rollback { private_blob.delete if copied }
          begin
            item = create!(report:, blob: private_blob, source:, source_id:, source_blob_id: origin_id,
                           checksum: blob.checksum, content_type: blob.content_type, byte_size: blob.byte_size)
            item.private_file.attach(private_blob)
            item
          rescue StandardError
            private_blob.delete if copied
            raise
          end
        end
      end

      def owned_private_blob?
        ReportPrivateStorage.private?(blob) && private_file.attached? && private_file.blob_id == blob_id
      end

      def ensure_private!
        return self if purged? || owned_private_blob?

        private_blob = ReportPrivateStorage.copy_private!(blob)
        copied = private_blob.id != blob_id
        ActiveRecord::Base.current_transaction.after_rollback { private_blob.delete if copied }
        begin
          update!(blob: private_blob) if copied
          private_file.attach(private_blob) unless private_file.attached? && private_file.blob_id == private_blob.id
          self
        rescue StandardError
          private_blob.delete if copied
          raise
        end
      end

      # Retain checksum/source and dispatch joins; attachment purge is durable
      # after commit and ActiveStorage protects any remaining source owner.
      def tombstone!
        return if purged?
        raise ArgumentError, "Evidence source must be private" unless ReportPrivateStorage.private?(blob)

        ReportEvidenceShare.where(evidence_item: self, revoked_at: nil).find_each(&:revoke!)
        descriptor = Infobip::EncryptedJobEnvelope.seal({ blob_id: blob.id, key: blob.key, service_name: blob.service_name },
                                                        purpose: "report-evidence-purge", salt: "bih-report-evidence-purge-v1")
        update!(blob: nil, purged_at: Time.current, purge_descriptor_ciphertext: descriptor, assessment: {}, sensitive_flags: [])
        ActiveRecord.after_all_transactions_commit { enqueue_purge }
      end

      def enqueue_purge
        ReportEvidencePurgeJob.perform_later(id) if purged? && purge_completed_at.nil? && purge_descriptor_ciphertext.present?
      rescue StandardError => e
        Rails.logger.warn("[report_evidence_purge] item_id=#{id} error=#{e.class}")
      end

      def self.sync_mail!(report)
        return unless defined?(InboundEmailLink) && InboundEmailLink.table_exists?

        InboundEmailLink.where(report:).includes(:inbound_email).find_each do |link|
          link.inbound_email.attachments.each { |file| register!(report:, blob: file.blob, source: "service_mail", source_id: link.inbound_email_id) }
        end
      end

      def self.sync!(report)
        register!(report:, blob: report.photo.blob, source: "original") if report.photo.attached?
        report.case_messages.order(:id).each do |message|
          register!(report:, blob: message.photo.blob, source: "citizen_message", source_id: message.id) if message.photo.attached?
          message.files.each { |file| register!(report:, blob: file.blob, source: "citizen_message", source_id: message.id) } if message.respond_to?(:files)
        end
        sync_mail!(report)
        live.where(report:).order(:id)
      end
    end
  end
end
