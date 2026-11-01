# frozen_string_literal: true

# rubocop:disable Layout/LineLength -- explicit schema and correlated SQL guards kept together

require "digest"

module Decidim
  module Bih
    module Ai
      # Minimal private review context, never contact metadata, bearer links,
      # attachments, account identifiers, or an unbounded conversation excerpt.
      class ReportReviewContext
        class TooLarge < StandardError; end
        ALLOWED_ACTIONS = %w(send ask duplicate plan review reject supplement followup).freeze
        MAX_BYTES = 48_000
        MAX_MESSAGES = 100
        MAX_DISPATCHES = 100
        attr_reader :report, :data, :sources

        def initialize(report)
          @report = report
          @sources = {}
          @names = ([report.author&.name, report.reviewed_by&.name, report.assigned_to&.name] + report.case_messages.includes(:actor).map do |message|
            message.actor&.name
          end).compact_blank
          @secrets = [report.status_token].compact_blank
          @secrets += ReportEvidenceShare.joins(:evidence_item).where(decidim_bih_report_evidence_items: { report_id: report.id }).map(&:token) if ReportEvidenceShare.table_exists?
          @data = build
          raise TooLarge if @data.to_json.bytesize > MAX_BYTES
        end

        def digest = Digest::SHA256.hexdigest(data.to_json)

        def redact(value)
          references = []
          dates = []
          file_numbers = []
          text = value.to_s.gsub(Redaction::URL_PATTERN, "[link]").gsub(Redaction::EMAIL_PATTERN, "[email]")
          text = text.gsub(/\bBR-\d{4}-\d{4,}\b/) do |reference|
            references << reference
            "REPORTREF#{references.length - 1}END"
          end
          text = text.gsub(/\b(?:0?[1-9]|[12]\d|3[01])\.(?:0?[1-9]|1[0-2])\.\d{4}\.?/) do |date|
            dates << date
            "QUOTEDDATE#{dates.length - 1}END"
          end
          text = text.gsub(%r{(?<![\p{L}\d])\d{2}/\d{2}-\d{1,6}/\d{2}(?!\d)}) do |number|
            file_numbers << number
            "MUNICIPALREF#{file_numbers.length - 1}END"
          end
          text = text.gsub(Redaction::PHONE_PATTERN, "[phone]").gsub(Redaction::SENSITIVE_ASSIGNMENT, '\\1[secret]')
          text = text.gsub(/REPORTREF(\d+)END/) { references[Regexp.last_match(1).to_i] || "[reference]" }
          text = text.gsub(/QUOTEDDATE(\d+)END/) { dates[Regexp.last_match(1).to_i] }
          text = text.gsub(/MUNICIPALREF(\d+)END/) { file_numbers[Regexp.last_match(1).to_i] }
          @names.each { |name| text = text.gsub(/(?<!\p{L})#{Regexp.escape(name)}(?!\p{L})/i, "[author]") }
          text = text.gsub(/\b[AEJKMOT]\d{2}-[AEJKMOT]-\d{3}\b/i, "[plate]")
          @secrets.each { |secret| text = text.gsub(secret, "[secret]") }
          text.lines.grep_v(/\A\s*(?:Kontakt|Telefon|Phone|Email|E-mail|From|To|Cc|Reply-To):/i).join
        end

        private

        # Match the background worker's configured zone, even for timestamps
        # already loaded in a request zone. This preserves existing proposal digests.
        def timestamp(value)
          value&.in_time_zone(Rails.application.config.time_zone || "UTC")&.iso8601
        end

        def source(id, text, role: "evidence")
          clean = redact(text)
          sources[id] = clean
          { id:, role:, text: clean }
        end

        def build
          {
            # Model configuration participates in the input digest so a model
            # change cannot reuse an earlier model's cached proposal.
            case_model: Config.report_case_model, case_check_model: Config.report_case_check_model,
            case_prompt_version: CaseAgent::PROMPT_VERSION,
            case_prompt_digest: Digest::SHA256.hexdigest(CaseAgent::INSTRUCTIONS + CaseDecision::SCHEMA.to_json),
            reference: report.reference, created_at: timestamp(report.created_at), status: report.status, review_state: report.review_state,
            forwarded: report.forwarded_at.present?, forwarded_at: timestamp(report.forwarded_at),
            reviewed_message_id: report.last_reviewed_message_id, dispatch_history: dispatch_history, planned: report.planned?, collection_id: report.report_collection_id,
            allowed_actions: ReportDecision.allowed_actions(report) & ALLOWED_ACTIONS,
            geometry: report.attributes.slice("location_kind", "latitude", "longitude", "location_end_latitude", "location_end_longitude"),
            classification: { category: report.category, severity: report.severity },
            evidence: evidence,
            conversation: messages(report),
            candidates: candidates,
            collections: collections,
            departments: ReportTaxonomy::CATEGORY_DEPARTMENT.transform_keys(&:to_s),
            routing_available: ReportTaxonomy::CATEGORIES.to_h { |category| [category.to_s, Sistem48::DepartmentRouting.email_for(category, report.organization).present?] },
            approved_recipient_keys: ReportRoutingGuide.recipient_keys(report.organization),
            categories: ReportTaxonomy::CATEGORIES.map(&:to_s), severities: ReportTaxonomy::SEVERITIES.map(&:to_s),
            details: report.has_attribute?(:details) ? report.details : {},
            open_obligations: open_obligations, correspondence: correspondence, evidence_items: evidence_items, routing_guidance: routing_guidance,
            photo_checksum: report.photo.attached? ? report.photo.blob.checksum : nil,
            photo: report.photo.attached? ? "present_but_not_examined" : "absent"
          }
        end

        def open_obligations
          return [] unless defined?(ReportObligation) && ReportObligation.table_exists?

          ReportObligations.for_report(report).sort_by { |item| item.id || 0 }.map do |item|
            { id: item.id, kind: item.kind, actor: item.actor, state: item.state, due_at: timestamp(item.due_at),
              source: { type: item.source_type, id: item.source_id }, metadata: redact(item.metadata.to_json) }
          end
        end

        def correspondence
          return [] unless defined?(InboundEmailLink) && InboundEmailLink.table_exists?

          InboundEmailLink.where(report:).includes(:inbound_email).order(:id).limit(MAX_MESSAGES + 1).map do |link|
            mail = link.inbound_email
            source("mail:#{mail.id}", mail.new_part, role: "service_mail").merge(id: mail.id, assurance: link.assurance, history_only: mail.history_only, no_auto_response: mail.no_auto_response, classification: mail.classification,
                                                                                 attachment_checksums: mail.attachments.order(:id).map do |attachment|
                                                                                   attachment.blob.checksum
                                                                                 end)
          end
        end

        def evidence_items
          return [] unless ReportEvidenceItem.table_exists?

          ReportEvidenceItem.live.where(report:).order(:id).map do |item|
            { id: item.id, checksum: item.checksum, content_type: item.content_type, byte_size: item.byte_size, assessment: redact(item.assessment_for_context.to_json),
              sensitive_flags: item.sensitive_flags, automatic_handoff: item.automatic_handoff? }
          end
        end

        def routing_guidance
          return [] unless ReportRoutingGuide.table_exists?

          ReportRoutingGuide.reviewed.where(organization: report.organization).order(:key).map do |guide|
            { key: guide.key, version: guide.version, body: redact(guide.body_sr), categories: guide.categories, approved_recipient_keys: guide.approved_recipient_keys }
          end
        end

        def dispatch_history
          rows = report.dispatches.order(:id).limit(MAX_DISPATCHES + 1).to_a
          raise TooLarge if rows.length > MAX_DISPATCHES

          rows.map do |dispatch|
            item = { kind: dispatch.kind, state: dispatch.state, approved_at: timestamp(dispatch.created_at),
                     accepted_at: timestamp(dispatch.accepted_at), content_available: dispatch.data_redacted_at.nil? }
            if dispatch.state == "accepted" && dispatch.data_redacted_at.nil?
              # Contact headers and local-area contacts are transport metadata,
              # not civic evidence. Never send mail routing or bearer links.
              body = dispatch.snapshot.fetch("body").lines.grep_v(/\A(?:Kontakt prijavioca|Predsjednik MZ|Telefon MZ):/).join
              item[:evidence] = source("dispatch:#{dispatch.id}", body, role: "accepted_outgoing_message")
            end
            item
          end
        end

        def evidence
          [source("original", report.description), source("location", report.address),
           source("forwarding_note", report.forwarding_note, role: "reviewed_note"),
           source("internal_note", report.internal_note, role: "private_staff_note")]
        end

        def messages(subject, prefix: "message")
          rows = subject.case_messages.order(:id).limit(MAX_MESSAGES + 1).to_a
          raise TooLarge if rows.length > MAX_MESSAGES

          rows.map do |message|
            checksums = [message.photo.attached? ? message.photo.blob.checksum : nil]
            checksums += message.files.map { |file| file.blob.checksum } if message.respond_to?(:files)
            source("#{prefix}:#{message.id}", message.body, role: message.actor_role).merge(
              kind: message.kind, at: timestamp(message.created_at), attachment_checksums: checksums.compact
            )
          end
        end

        def candidates
          ReportDuplicateCandidates.new(report).call.first(4).map do |match|
            candidate = match.report
            @names << candidate.author.name if candidate.author&.name.present?
            { reference: candidate.reference, basis: match.basis, category: candidate.category, status: candidate.status,
              created_at: timestamp(candidate.created_at),
              evidence: [source("candidate:#{candidate.reference}:original", candidate.description),
                         source("candidate:#{candidate.reference}:location", candidate.address)],
              conversation: messages(candidate, prefix: "candidate:#{candidate.reference}:message") }
          end
        end

        def collections
          ReportCollection.where(organization: report.organization, state: %w(collecting ready)).order(:id).limit(20).map do |collection|
            { id: collection.id, state: collection.state,
              evidence: [source("collection:#{collection.id}:title", collection.title),
                         source("collection:#{collection.id}:topic", collection.topic),
                         source("collection:#{collection.id}:summary", collection.summary)] }
          end
        end
      end
    end
  end
end

# rubocop:enable Layout/LineLength
