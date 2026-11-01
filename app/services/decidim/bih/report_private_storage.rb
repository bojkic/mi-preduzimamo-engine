# frozen_string_literal: true

require "stringio"
require "active_storage/service/encrypted_private_disk_service"

module Decidim
  module Bih
    module ReportPrivateStorage
      SERVICE = "report_private"
      Unavailable = ActiveStorage::Service::EncryptedPrivateDiskService::Unavailable

      module_function

      def service_name
        service
        SERVICE
      end

      def service
        configured = ActiveStorage::Blob.services.fetch(SERVICE)
        raise Unavailable, "Private attachment storage is not encrypted" unless configured.is_a?(ActiveStorage::Service::EncryptedPrivateDiskService) && !configured.public?

        configured
      rescue KeyError
        raise Unavailable, "Private attachment storage is not configured"
      end

      def private?(blob)
        blob && blob.service_name == SERVICE && blob.service.equal?(service)
      end

      def download!(blob)
        raise Unavailable, "Private attachment requires conversion" unless private?(blob)

        blob.download
      end

      def stable_source_blob_id(blob)
        Integer(blob.metadata.fetch("report_private_source_blob_id", blob.id))
      end

      def copy_private!(blob)
        return blob if private?(blob)
        raise Unavailable, "Private source exceeds its bound" unless blob.byte_size.between?(0, service.max_bytes)

        ActiveStorage::Blob.transaction do
          replacement = nil
          blob.open do |file|
            replacement = ActiveStorage::Blob.create_after_unfurling!(io: file, filename: blob.filename.to_s,
                                                                      content_type: blob.content_type, identify: false, service_name: SERVICE,
                                                                      metadata: blob.metadata.merge("report_private_source_blob_id" => stable_source_blob_id(blob)))
            storage = replacement.service
            key = replacement.key
            # This fresh row cannot have a committed owner while its insertion is uncommitted.
            # The callback follows an enclosing transaction too, unlike an after-commit rescue.
            ActiveRecord::Base.current_transaction.after_rollback { storage.delete(key) }
            replacement.upload_without_unfurling(file)
          end
          raise ActiveStorage::IntegrityError, "Private copy identity mismatch" unless replacement.checksum == blob.checksum && replacement.byte_size == blob.byte_size

          replacement
        end
      end

      def convert_attachment!(attachment)
        allowed_private_attachment!(attachment)
        replacement = nil
        cleanup = nil
        attachment.with_lock do
          original = attachment.blob
          if private?(original)
            replacement = original
            next
          end
          replacement = copy_private!(original)
          cleanup = ReportPrivateStorageCleanup.create!(organization: organization_for(attachment),
                                                        attachment_id: attachment.id, original_blob_id: original.id, replacement_blob_id: replacement.id,
                                                        original_service_name: original.service_name, original_key: original.key)
          # Storage-only conversion must not mint notifications or alter case/race timestamps.
          attachment.update_columns(blob_id: replacement.id) # rubocop:disable Rails/SkipsModelValidations -- storage pointer only, preserve case timestamps/callbacks
        end
        ActiveRecord.after_all_transactions_commit { cleanup.recover! } if cleanup
        replacement
      end

      def organization_for(attachment)
        record = attachment.record
        record.is_a?(InboundEmail) ? record.organization : record.report.organization
      end

      def allowed_private_attachment!(attachment)
        allowed = { "Decidim::Bih::InboundEmail" => %w(attachments), "Decidim::Bih::ReportMessage" => %w(photo files),
                    "Decidim::Bih::ReportEvidenceItem" => %w(private_file) }
        raise Unavailable, "Not a private report attachment" unless allowed.fetch(attachment.record.class.name, []).include?(attachment.name)
      end

      def retained?(blob)
        return true if blob.attachments.exists?

        defined?(ReportEvidenceItem) && ReportEvidenceItem.table_exists? && ReportEvidenceItem.exists?(blob_id: blob.id)
      end
    end
  end
end
