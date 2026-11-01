# frozen_string_literal: true

require "base64"

module Decidim
  module Bih
    # Bounded, immutable mail copies. Bytes live in the existing encrypted dispatch
    # snapshot and follow its retention policy, independently of later uploads.
    module ReportEvidence
      MAX_MAIL_BYTES = 15.megabytes
      module_function

      def record_dispatch!(dispatch, evidence_item_ids: nil, request_source: nil)
        items = ReportEvidenceItem.sync!(dispatch.report)
        if evidence_item_ids
          items = items.where(id: evidence_item_ids)
          raise ReportDispatching::Invalid, 'unknown_evidence' unless items.count == evidence_item_ids.uniq.length
        else
          # Match immutable outgoing bytes, never assume every current upload
          # was sent. ActiveStorage checksums are base64 MD5.
          checksums = Array(dispatch.snapshot['attachments']).map do |attachment|
            Base64.strict_encode64(Digest::MD5.digest(Base64.strict_decode64(attachment.fetch('content'))))
          end
          items = items.where(checksum: checksums)
        end
        items.each do |item|
          if request_source && ReportDispatchEvidence.sent_for_request?(item, request_source)
            existing = ReportDispatchEvidence.find_by(dispatch:, evidence_item: item, request_source:)
            next if existing
            raise ReportDispatching::Invalid, 'evidence_already_sent_for_request'
          end
          ReportDispatchEvidence.find_or_create_by!(dispatch:, evidence_item: item, request_source:)
        end
      end

      def approved_conversation_dispatch(report, recipient)
        digest = Digest::SHA256.hexdigest(recipient.to_s.downcase.strip)
        return unless ReportServiceSender.active.exists?(organization: report.organization, email_digest: digest)
        report.dispatches.where(state: 'accepted', kind: 'initial').where.not(approved_by_id: nil).order(id: :desc).find do |dispatch|
          Array(dispatch.snapshot['to']).any? { |address| address.to_s.downcase.strip == recipient.to_s.downcase.strip }
        end
      end

      # Prepare bearer links before rollback-only preview, like reply capabilities.
      # They are initially bound to the approved human conversation and rebound
      # to the supplement atomically when its immutable snapshot is created.
      def prepare_service_evidence!(report:, evidence_item_ids:, recipient:, request_source:, allow_create: true)
        initial = approved_conversation_dispatch(report, recipient)
        raise ReportDispatching::Invalid, 'unapproved_correspondent' unless initial && request_source
        recipient_digest = Digest::SHA256.hexdigest(recipient.downcase.strip)
        link = request_source.is_a?(InboundEmail) && InboundEmailLink.find_by(report:, inbound_email: request_source)
        raise ReportDispatching::Invalid, 'untrusted_evidence_request' unless link && %w(capability authenticated_thread).include?(link.assurance) &&
          request_source.from_digest == recipient_digest && !request_source.history_only && !request_source.no_auto_response && request_source.classification == 'candidate'
        report.with_lock do
          items = ReportEvidenceItem.live.where(report:, id: evidence_item_ids)
          raise ReportDispatching::Invalid, 'unknown_evidence' unless items.count == evidence_item_ids.uniq.size
          result = { attachments: [], links: [], share_ids: [] }
          total = 0
          items.order(:id).each do |item|
            raise ReportDispatching::Invalid, 'sensitive_or_unassessed_evidence' unless item.automatic_handoff?
            raise ReportDispatching::Invalid, 'evidence_already_sent_for_request' if ReportDispatchEvidence.sent_for_request?(item, request_source)
            if total + item.byte_size <= MAX_MAIL_BYTES
              result[:attachments] << { filename: item.blob.filename.to_s, content_type: item.content_type, content: Base64.strict_encode64(item.blob.download), byte_size: item.byte_size }
              total += item.byte_size
            else
              share = ReportEvidenceShare.find_by(evidence_item: item, request_source:, recipient_digest:)
              raise ReportDispatching::Invalid, 'evidence_share_not_prepared' unless share || allow_create
              share ||= ReportEvidenceShare.issue!(evidence_item: item, dispatch: initial, recipient:, request_source:)
              raise ReportDispatching::Invalid, 'evidence_share_expired_or_revoked' unless share.revoked_at.nil? && share.expires_at > Time.current
              host = report.organization.host
              raise ReportDispatching::Invalid, 'invalid_organization_host' unless host.match?(/\A[a-z0-9.-]+\z/i)
              path = Decidim::Bih::Engine.routes.url_helpers.service_evidence_share_path(token: share.token)
              result[:links] << { evidence_item_id: item.id, url: "https://#{host}#{path}" }
              result[:share_ids] << share.id
            end
          end
          result
        end
      end

      def service_evidence(report:, evidence_item_ids:, recipient:, request_source:)
        prepare_service_evidence!(report:, evidence_item_ids:, recipient:, request_source:, allow_create: false)
      end

      def bind_service_shares!(dispatch, share_ids:)
        shares = ReportEvidenceShare.where(id: share_ids)
        raise ReportDispatching::Invalid, 'unknown_evidence_share' unless shares.count == share_ids.uniq.size
        shares.each do |share|
          raise ReportDispatching::Invalid, 'cross_case_evidence_share' unless share.evidence_item.report_id == dispatch.report_id
          share.update!(dispatch:)
        end
      end

      def service_attachments(report:, evidence_item_ids:, recipient:, request_source:)
        raise ReportDispatching::Invalid, 'unapproved_recipient' unless approved_conversation_dispatch(report, recipient)
        items = ReportEvidenceItem.live.where(report:, id: evidence_item_ids)
        raise ReportDispatching::Invalid, 'unknown_evidence' unless items.count == evidence_item_ids.uniq.size
        items.map do |item|
          raise ReportDispatching::Invalid, 'sensitive_or_unassessed_evidence' unless item.automatic_handoff?
          raise ReportDispatching::Invalid, 'evidence_already_sent_for_request' if ReportDispatchEvidence.sent_for_request?(item, request_source)
          if item.byte_size > MAX_MAIL_BYTES
            raise ReportDispatching::Invalid, 'private_evidence_link_required'
          end
          { filename: item.blob.filename.to_s, content_type: item.content_type,
            content: Base64.strict_encode64(item.blob.download), byte_size: item.byte_size }
        end
      end

      def normalize(upload)
        return if upload.blank?

        invalid! unless upload.respond_to?(:tempfile) && upload.size <= Report::PHOTO_MAX_BYTES
        detected = Marcel::MimeType.for(upload.tempfile)
        invalid! unless Report::PHOTO_CONTENT_TYPES.include?(detected) && detected == upload.content_type
        normalized = Media::ImageNormalizer.call(upload)
        invalid! unless normalized
        if normalized[:io].size > Report::PHOTO_MAX_BYTES
          normalized[:io].close!
          invalid!
        end
        normalized
      end

      def invalid!
        raise ReportCaseWorkflow::Invalid, I18n.t("decidim.bih.report_evidence.invalid_photo")
      end

      def attachments(report, kind: "initial")
        return [] if kind == "followup"

        photos = []
        photos << ["original", report.photo.blob] if report.photo.attached?
        if kind == "supplement"
          report.case_messages.where(actor_role: "citizen").with_attached_photo.order(:id).each do |message|
            photos << ["reply-#{message.id}", message.photo.blob] if message.photo.attached?
          end
        end
        if photos.sum { |_, blob| blob.byte_size } > MAX_MAIL_BYTES
          raise ReportDispatching::Invalid, I18n.t("decidim.bih.report_evidence.mail_too_large")
        end
        photos.map do |source, blob|
          invalid! unless Report::PHOTO_CONTENT_TYPES.include?(blob.content_type)
          bytes = blob.download
          extension = Media::ImageNormalizer::EXTENSION_FOR.fetch(blob.content_type)
          { filename: "#{report.reference}-#{source}#{extension}", content_type: blob.content_type,
            content: Base64.strict_encode64(bytes), byte_size: bytes.bytesize }
        end
      end

      def snapshot(mail)
        { to: mail.to, from: mail.from, subject: mail.subject, reply_to: mail.reply_to,
          in_reply_to: mail.in_reply_to, references: mail.references,
          body: (mail.text_part || mail).body.decoded,
          attachments: mail.attachments.map do |attachment|
            bytes = attachment.body.decoded
            { filename: attachment.filename, content_type: attachment.mime_type,
              content: Base64.strict_encode64(bytes), byte_size: bytes.bytesize }
          end }
      end

      def attach(mail, entries)
        entries.each do |entry|
          item = entry.symbolize_keys
          mail.attachments[item.fetch(:filename)] = { mime_type: item.fetch(:content_type), content: Base64.strict_decode64(item.fetch(:content)) }
        end
      end
    end
  end
end
