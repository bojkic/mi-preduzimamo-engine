# frozen_string_literal: true

module Decidim
  module Bih
    # Durable storage deletion intent, committed with the attachment pointer swap.
    # Recovery deletes only this known converted source, never age-based ciphertext orphans.
    class ReportPrivateStorageCleanup < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_private_storage_cleanups"
      belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
      validates :state, inclusion: { in: %w(pending retained disk_pending cleaned) }
      self.filter_attributes += [:original_key, :original_key_ciphertext]

      def original_key
        Infobip::EncryptedJobEnvelope.open(original_key_ciphertext,
                                           purpose: "report-private-cleanup", salt: "bih-private-cleanup-v1").fetch("key")
      end

      def original_key=(value)
        self.original_key_ciphertext = Infobip::EncryptedJobEnvelope.seal({ key: value },
                                                                          purpose: "report-private-cleanup", salt: "bih-private-cleanup-v1")
      end

      def self.recover_pending!(organization_id: nil, limit: 100)
        scope = where(state: %w(pending retained disk_pending)).order(Arel.sql("last_attempted_at ASC NULLS FIRST, id ASC"))
        scope = scope.where(decidim_organization_id: organization_id) if organization_id
        scope.limit(Integer(limit).clamp(1, 100)).each(&:recover!)
      end

      def recover!
        return if state == "cleaned"
        # Byte deletion must never precede the enclosing database commit.
        return false if self.class.connection.transaction_open?

        update!(last_attempted_at: Time.current)
        detach_original!
        return unless reload.state == "disk_pending"

        delete_original_file!
      rescue StandardError => e
        update!(last_error_class: e.class.name, updated_at: Time.current)
        Rails.logger.error("[report-private-storage] cleanup id=#{id} error=#{e.class.name}")
        false
      end

      private

      def detach_original!
        with_lock do
          next if %w(cleaned disk_pending).include?(state)

          blob = ActiveStorage::Blob.find_by(id: original_blob_id)
          if blob
            blob.with_lock do
              raise ReportPrivateStorage::Unavailable, "Private conversion source identity changed" unless blob.service_name == original_service_name && blob.key == original_key

              if ReportPrivateStorage.retained?(blob)
                update!(state: "retained")
                next
              end
              # FK locking and restrictions protect any concurrent or additional owner.
              # Commit the row deletion BEFORE deleting bytes, retaining the durable key.
              blob.destroy!
              update!(state: "disk_pending", last_error_class: nil)
            end
          else
            update!(state: "disk_pending", last_error_class: nil)
          end
        end
      rescue ActiveRecord::InvalidForeignKey, ActiveRecord::DeleteRestrictionError
        update!(state: "retained")
      end

      def delete_original_file!
        with_lock do
          next unless state == "disk_pending"

          key = original_key
          # Never delete a key that still has a committed authoritative Blob owner.
          if ActiveStorage::Blob.exists?(service_name: original_service_name, key:)
            update!(state: "retained")
            next
          end
          storage = ActiveStorage::Blob.services.fetch(original_service_name)
          storage.delete(key)
          storage.delete_prefixed("variants/#{key}/")
          update!(state: "cleaned", cleaned_at: Time.current, last_error_class: nil)
        end
      end
    end
  end
end
