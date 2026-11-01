# frozen_string_literal: true

module Decidim
  module Bih
    # Descriptor survives attachment detachment and blob-row deletion. Physical
    # deletion follows committed ownership changes, outside their transaction.
    class ReportEvidencePurgeJob < ApplicationJob
      queue_as :default

      def perform(item_id)
        item = ReportEvidenceItem.find_by(id: item_id)
        return unless item

        descriptor = detach_owned_file(item)
        return unless descriptor

        blob = ActiveStorage::Blob.find_by(id: descriptor.fetch("blob_id"))
        blob ? purge_blob(blob, descriptor) : purge_file(descriptor)
        item.update!(purge_completed_at: Time.current, purge_descriptor_ciphertext: nil)
      end

      private

      def detach_owned_file(item)
        item.with_lock do
          next unless item.purged? && item.purge_completed_at.nil?

          descriptor = Infobip::EncryptedJobEnvelope.open(item.purge_descriptor_ciphertext,
                                                          purpose: "report-evidence-purge", salt: "bih-report-evidence-purge-v1")
          raise ArgumentError, "Evidence source must be private" unless descriptor.fetch("service_name") == "report_private"

          item.private_file.detach if item.private_file.attached?
          descriptor
        end
      end

      def purge_blob(blob, descriptor)
        raise ArgumentError, "Evidence cleanup identity changed" unless ReportPrivateStorage.private?(blob) && blob.key == descriptor.fetch("key")

        blob.purge
        return unless ActiveStorage::Blob.exists?(blob.id)

        retained = ActiveStorage::Attachment.exists?(blob_id: blob.id) || ReportEvidenceItem.live.exists?(blob_id: blob.id)
        raise ActiveStorage::IntegrityError, "Evidence cleanup retained without an owner" unless retained
      end

      def purge_file(descriptor)
        service = ActiveStorage::Blob.services.fetch(descriptor.fetch("service_name"))
        raise ArgumentError, "Evidence cleanup service changed" unless service.is_a?(ActiveStorage::Service::EncryptedPrivateDiskService)

        service.delete(descriptor.fetch("key"))
        service.delete_prefixed("variants/#{descriptor.fetch("key")}/")
      end
    end
  end
end
