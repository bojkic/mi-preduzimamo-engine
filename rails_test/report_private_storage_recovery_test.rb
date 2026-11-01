# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportPrivateStorageRecoveryTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        setup do
          @organization = create_organization
          @email = InboundEmail.create!(organization: @organization, account: "fixture@example.org", folder: "All",
                                        gm_msgid: SecureRandom.uuid, uid: 1, uidvalidity: 1, internal_date: Time.current, size_bytes: 10)
          @blob_ids = []
        end

        teardown do
          ActiveStorage::Attachment.where(record: @email).delete_all
          ReportPrivateStorageCleanup.where(organization: @organization).delete_all
          ActiveStorage::Blob.where(id: @blob_ids).each(&:purge)
          @email.destroy!
          @organization.static_pages.delete_all
          @organization.destroy!
        end

        def source
          blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("private fixture"), filename: "fixture.txt", content_type: "text/plain")
          @blob_ids << blob.id
          blob
        end

        def intent(blob, replacement)
          ReportPrivateStorageCleanup.create!(organization: @organization, attachment_id: 1,
                                              original_blob_id: blob.id, replacement_blob_id: replacement.id,
                                              original_service_name: blob.service_name, original_key: blob.key)
        end

        def interrupted_conversion
          blob = source
          attachment = ActiveStorage::Attachment.create!(record: @email, name: "attachments", blob:)
          replacement = nil
          cleanup = nil
          ActiveRecord::Base.transaction do
            replacement = ReportPrivateStorage.copy_private!(blob)
            @blob_ids << replacement.id
            cleanup = intent(blob, replacement)
            attachment.update_columns(blob_id: replacement.id) # rubocop:disable Rails/SkipsModelValidations -- reproduce the committed storage-only pointer swap
          end
          # Simulates loss of the after-commit fast path; durable intent remains real.
          [blob, replacement, cleanup]
        end

        test "recovery cleans a committed pointer conversion after process interruption" do
          original, replacement, cleanup = interrupted_conversion
          assert original.service.exist?(original.key)
          cleanup.recover!
          assert_equal "cleaned", cleanup.reload.state
          refute ActiveStorage::Blob.exists?(original.id)
          refute original.service.exist?(original.key)
          assert_equal "private fixture", replacement.download
          assert cleanup.recover!.nil?
        end

        test "disk deletion interruption is retryable after original row deletion" do
          original, replacement, cleanup = interrupted_conversion
          original.service.stub(:delete, ->(*) { raise IOError, "synthetic interruption" }) { refute cleanup.recover! }
          assert_equal "disk_pending", cleanup.reload.state
          refute ActiveStorage::Blob.exists?(original.id)
          assert original.service.exist?(original.key)
          cleanup.recover!
          assert_equal "cleaned", cleanup.reload.state
          refute original.service.exist?(original.key)
          assert_equal "private fixture", replacement.download
        end

        test "shared originals are retained and a full retained batch does not starve later cleanup" do
          shared = source
          ActiveStorage::Attachment.create!(record: @email, name: "attachments", blob: shared)
          100.times { intent(shared, shared) }
          original, _replacement, eligible = interrupted_conversion
          ReportPrivateStorageCleanup.recover_pending!(organization_id: @organization.id)
          assert_equal "pending", eligible.reload.state
          assert_equal 100, ReportPrivateStorageCleanup.where(organization: @organization, state: "retained").count
          ReportPrivateStorageCleanup.recover_pending!(organization_id: @organization.id)
          assert_equal "cleaned", eligible.reload.state
          refute original.service.exist?(original.key)
          assert shared.service.exist?(shared.key)
          assert ActiveStorage::Blob.exists?(shared.id)
        end

        test "cleanup never deletes bytes before an enclosing commit" do
          original, _replacement, cleanup = interrupted_conversion
          ActiveRecord::Base.transaction do
            refute cleanup.recover!
            assert ActiveStorage::Blob.exists?(original.id)
            assert original.service.exist?(original.key)
          end
          cleanup.recover!
          assert_equal "cleaned", cleanup.reload.state
        end
      end
    end
  end
end
