# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    # An operator approves the entire current case, not just its outbound text.
    # Draft edits and assignment changes invalidate competing browser tabs too.
    module ReportReviewVersion
      module_function

      def digest(report)
        Digest::SHA256.hexdigest(canonical({
                                             forwarding: ReportCaseWorkflow.digest(report),
                                             details: report.attributes.slice("duplicate_of_report_id", "report_collection_id", "status_note", "resolution_evidence",
                                                                              "internal_note", "assigned_to_id", "response_due_at", "review_draft", "resident_feedback"),
                                             messages: report.case_messages.order(:id).pluck(:id, :actor_role, :kind, :body),
                                             attachment_checksums: attachment_checksums(report),
                                             collection: report.report_collection&.attributes&.slice("state", "updated_at"),
                                             dispatches: report.dispatches.order(:id).pluck(:id, :state)
                                           }).to_json)
      end

      def attachment_checksums(report)
        original = report.photo.attached? ? report.photo.blob.checksum : nil
        messages = report.case_messages.order(:id).map do |message|
          [message.id, message.photo.attached? ? message.photo.blob.checksum : nil,
           message.respond_to?(:files) ? message.files.map { |file| file.blob.checksum } : []]
        end
        [original, messages]
      end

      # PostgreSQL jsonb normalizes object-key order. Equal drafts must have the
      # same version before and after reload, while array/message order matters.
      def canonical(value)
        case value
        when Hash then value.stringify_keys.sort.to_h.transform_values { |entry| canonical(entry) }
        when Array then value.map { |entry| canonical(entry) }
        else value
        end
      end
    end
  end
end
