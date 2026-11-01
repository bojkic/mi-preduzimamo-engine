# frozen_string_literal: true

require "stringio"

module Decidim
  module Bih
    module ReportMailbox
      module CitizenReply
        CONTENT_TYPES = (Report::PHOTO_CONTENT_TYPES + ["application/pdf"]).freeze
        MAX_FILE_BYTES = 10.megabytes
        MAX_TOTAL_BYTES = 25.megabytes
        def self.validated_files(files)
          total = 0
          Array(files).map do |file|
            io = file.is_a?(Hash) ? file.fetch(:io) : file.tempfile
            type = Marcel::MimeType.for(io)
            declared = file.is_a?(Hash) ? file.fetch(:content_type) : file.content_type
            io.rewind
            size = io.size
            total += size
            raise ReportCaseWorkflow::Invalid, I18n.t("decidim.bih.report_evidence.invalid_photo") unless CONTENT_TYPES.include?(type) && type == declared && size <= MAX_FILE_BYTES && total <= MAX_TOTAL_BYTES
            file
          end
        end
        def self.record!(report:, inbound_email:, capability:)
          return if inbound_email.history_only
          mail = Mail.read_from_string(inbound_email.raw)
          sender = Array(mail.from)
          unless capability && capability.audience == "citizen" && capability.report == report && !capability.revoked_at &&
                 sender.one? && capability.correspondent?(sender.first) && report.author&.confirmed? && report.author.email.casecmp?(sender.first)
            raise Decidim::ActionForbidden
          end
          files = []
          flags = []
          total = 0
          mail.attachments.each_with_index do |attachment, index|
            bytes = attachment.body.decoded
            type = Marcel::MimeType.for(StringIO.new(bytes))
            if !CONTENT_TYPES.include?(type) || type != attachment.mime_type || bytes.bytesize > MAX_FILE_BYTES || total + bytes.bytesize > MAX_TOTAL_BYTES
              flags << "attachment_rejected"
              next
            end
            total += bytes.bytesize
            # Untrusted filenames never enter a path or a rendered HTML attribute.
            extension = type == "application/pdf" ? ".pdf" : Media::ImageNormalizer::EXTENSION_FOR.fetch(type)
            files << { io: StringIO.new(bytes), filename: "#{report.reference}-reply-#{index}#{extension}", content_type: type }
          end
          body = inbound_email.new_part.presence || I18n.t("decidim.bih.report_mailbox.attachment_reply")
          message = report.case_messages.create!(actor: report.author, actor_role: "citizen", kind: "reply", body: body.first(3000), answers_message: capability&.question_message)
          message.files.attach(files)
          report.record_event!("city_email_citizen_reply", actor: report.author, source: "background", metadata: { inbound_email_id: inbound_email.id, message_id: message.id, flags: })
          # No reopen or legacy review/status changes in the additive release.
          ActiveRecord.after_all_transactions_commit { ReportCaseMessageJob.perform_later(message.id) }
          ReportCityReply::StaffNotice.call(report:, inbound_email:, reason: "citizen_after_closure") if %w(rijeseno zatvoreno odbijeno).include?(report.status)
          ActiveRecord.after_all_transactions_commit { ReportReviewAssistant.enqueue(report) }
          message
        end
      end
    end
  end
end
