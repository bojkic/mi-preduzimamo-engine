# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportPrivateStorageTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @email = InboundEmail.create!(organization: @organization, account: "fixture@example.org", folder: "All",
                                        gm_msgid: SecureRandom.uuid, uid: 1, uidvalidity: 1, internal_date: Time.current, size_bytes: 10)
        end

        def plaintext_blob
          ActiveStorage::Blob.create_and_upload!(io: StringIO.new("synthetic attachment"),
                                                 filename: "fixture.txt", content_type: "text/plain", service_name: ActiveStorage::Blob.service.name)
        end

        def legacy_attachment(blob = plaintext_blob)
          # Simulates a persisted pre-encryption row, rather than bypassing normal upload validation.
          ActiveStorage::Attachment.create!(record: @email, name: "attachments", blob:)
        end

        test "new inbound attachments use encrypted service with unchanged plaintext metadata" do
          @email.attachments.attach(io: StringIO.new("synthetic attachment"), filename: "fixture.txt", content_type: "text/plain")
          blob = @email.attachments.first.blob
          assert ReportPrivateStorage.private?(blob)
          assert_equal "synthetic attachment", ReportPrivateStorage.download!(blob)
          assert_equal 20, blob.byte_size
          assert_equal "text/plain", blob.content_type
          assert_equal OpenSSL::Digest::MD5.base64digest("synthetic attachment"), blob.checksum
          refute_includes File.binread(blob.service.path_for(blob.key)), "synthetic attachment"
        end

        test "private case photos and files select encryption without changing public report photos" do
          report = Report.create!(organization: @organization, description: "Fixture", category: "rasvjeta", severity: "normalan")
          message = report.case_messages.create!(actor_role: "citizen", kind: "reply", body: "Fixture")
          message.photo.attach(io: StringIO.new("photo fixture"), filename: "photo.txt", content_type: "text/plain")
          message.files.attach(io: StringIO.new("file fixture"), filename: "file.txt", content_type: "text/plain")
          assert ReportPrivateStorage.private?(message.photo.blob)
          assert ReportPrivateStorage.private?(message.files.first.blob)
          assert message.reload.valid?
          public_blob = plaintext_blob
          ActiveStorage::Attachment.create!(record: report, name: "photo", blob: public_blob)
          refute ReportPrivateStorage.private?(report.reload.photo.blob)
        end

        test "case attachment conversion audits actual status permission and preserves case state timestamps" do
          actor = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          report = Report.create!(organization: @organization, description: "Fixture", category: "rasvjeta", severity: "normalan")
          message = report.case_messages.create!(actor_role: "citizen", kind: "reply", body: "Fixture")
          attachment = ActiveStorage::Attachment.create!(record: message, name: "files", blob: plaintext_blob)
          report.reload
          message.reload
          original = [report.status, report.updated_at, message.updated_at]
          result = ReportPrivateStorageConversion.call(organization: @organization, actor:, attachment_ids: [attachment.id],
                                                       apply: true, confirmation: "ENCRYPT_PRIVATE_ATTACHMENTS")
          assert result.first[:converted]
          assert ReportPrivateStorage.private?(attachment.reload.blob)
          assert_equal original, [report.reload.status, report.updated_at, message.reload.updated_at]
          audit = OperatorAuditEvent.where(organization: @organization, event_type: "report_private_attachment_encrypted").last
          assert_equal "reports_update_status", audit.permission
          assert_equal attachment.id, audit.metadata.fetch("attachment_id")
        end

        test "existing ordinary blob cannot bypass private attachment validation" do
          attachment = legacy_attachment
          refute @email.reload.valid?
          assert_includes @email.errors[:attachments], "requires encrypted private storage"
          assert_raises(ReportPrivateStorage::Unavailable) { ReportPrivateStorage.download!(attachment.blob) }
        end

        test "private copy preserves stable source provenance and outer rollback removes only its new bytes" do
          original = plaintext_blob
          replacement = nil
          ActiveStorage::Blob.transaction(requires_new: true) do
            replacement = ReportPrivateStorage.copy_private!(original)
            assert_equal original.id, ReportPrivateStorage.stable_source_blob_id(replacement)
            assert_equal original.checksum, replacement.checksum
            assert replacement.service.exist?(replacement.key)
            raise ActiveRecord::Rollback
          end
          refute ActiveStorage::Blob.exists?(replacement.id)
          refute replacement.service.exist?(replacement.key)
          assert original.service.exist?(original.key)
          assert_equal "synthetic attachment", original.download
        end

        test "failed pointer update rolls back replacement and cleanup intent while keeping source" do
          attachment = legacy_attachment
          original = attachment.blob
          key = nil
          service = ReportPrivateStorage.service
          original_upload = service.method(:upload)
          service.stub(:upload, lambda { |candidate, *args, **kwargs|
            key = candidate
            original_upload.call(candidate, *args, **kwargs)
          }) do
            attachment.stub(:update_columns, ->(*) { raise ActiveRecord::StatementInvalid, "synthetic pointer failure" }) do
              assert_no_difference("ReportPrivateStorageCleanup.count") do
                assert_raises(ActiveRecord::StatementInvalid) { ReportPrivateStorage.convert_attachment!(attachment) }
              end
            end
          end
          refute service.exist?(key)
          assert_equal original.id, attachment.reload.blob_id
          assert original.service.exist?(original.key)
        end

        test "conversion refuses public report photos" do
          report = Report.create!(organization: @organization, description: "Fixture", category: "rasvjeta", severity: "normalan")
          attachment = ActiveStorage::Attachment.create!(record: report, name: "photo", blob: plaintext_blob)
          assert_raises(ReportPrivateStorage::Unavailable) { ReportPrivateStorage.convert_attachment!(attachment) }
        end

        test "conversion dry-run and permission scope preserve report message authorization provenance" do
          actor = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          attachment = legacy_attachment
          result = ReportPrivateStorageConversion.call(organization: @organization, actor:, attachment_ids: [attachment.id])
          refute result.first[:converted]
          assert_equal "pending", ReportPrivateStorageCleanup.new.state
          assert_raises(ArgumentError) do
            ReportPrivateStorageConversion.call(organization: @organization, actor:, attachment_ids: [attachment.id], apply: true)
          end
          other = create_organization
          assert_raises(Decidim::ActionForbidden) do
            ReportPrivateStorageConversion.call(organization: other, actor:, attachment_ids: [attachment.id])
          end
        end
      end
    end
  end
end
