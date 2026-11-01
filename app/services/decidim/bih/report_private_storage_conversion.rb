# frozen_string_literal: true

module Decidim
  module Bih
    class ReportPrivateStorageConversion
      MAX_ATTACHMENTS = 100

      def self.call(organization:, actor:, attachment_ids:, apply: false, confirmation: nil)
        authorize_actor!(organization:, actor:)

        ids, attachments = selected_attachments(attachment_ids)
        attachments.each { |attachment| authorize!(attachment, organization:, actor:) }
        raise ArgumentError, "Explicit conversion confirmation required" if apply && confirmation != "ENCRYPT_PRIVATE_ATTACHMENTS"

        result = attachments.map { |attachment| convert_selected(attachment, organization:, actor:, apply:) }
        ReportPrivateStorageCleanup.where(organization:, attachment_id: ids).where.not(state: "cleaned").each(&:recover!) if apply
        result
      end

      def self.authorize_actor!(organization:, actor:)
        raise Decidim::ActionForbidden unless actor&.organization == organization && actor.confirmed?
      end

      def self.selected_attachments(attachment_ids)
        ids = Array(attachment_ids).map { |id| Integer(id) }
        raise ArgumentError, "Explicit bounded attachment IDs required" if ids.empty? || ids.size > MAX_ATTACHMENTS || ids.uniq != ids

        attachments = ActiveStorage::Attachment.where(id: ids).order(:id).to_a
        raise ActiveRecord::RecordNotFound unless attachments.size == ids.size

        [ids, attachments]
      end

      def self.permission_for(attachment)
        attachment.record.is_a?(InboundEmail) ? :reports_mailbox_manage : :reports_update_status
      end

      def self.authorize!(attachment, organization:, actor:)
        ReportPrivateStorage.allowed_private_attachment!(attachment)
        unless ReportPrivateStorage.organization_for(attachment) == organization &&
               OperatorAuthorization.allowed?(actor, permission_for(attachment), organization:)
          raise Decidim::ActionForbidden
        end
      end

      def self.convert_selected(attachment, organization:, actor:, apply:)
        encrypted = ReportPrivateStorage.private?(attachment.blob)
        convert_and_audit!(attachment, organization:, actor:) if apply && !encrypted
        { attachment_id: attachment.id, encrypted_before: encrypted, converted: apply && !encrypted }
      end

      def self.convert_and_audit!(attachment, organization:, actor:)
        original_id = attachment.blob_id
        attachment.transaction do
          blob = ReportPrivateStorage.convert_attachment!(attachment)
          OperatorAuditEvent.record!(organization:, actor:, event_type: "report_private_attachment_encrypted",
                                     permission: permission_for(attachment), resource: attachment,
                                     metadata: { attachment_id: attachment.id, old_blob_id: original_id, new_blob_id: blob.id })
        end
      end
    end
  end
end
