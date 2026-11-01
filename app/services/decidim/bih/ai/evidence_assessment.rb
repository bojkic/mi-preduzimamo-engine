# frozen_string_literal: true

require "base64"
module Decidim
  module Bih
    module Ai
      class EvidenceAssessment
        FORMAT = "visual-codes-v1"
        MAX_BYTES = 8.megabytes
        CONTENT_TYPES = %w(image/jpeg image/png image/webp application/pdf).freeze
        OBSERVATIONS = {
          "road_damage" => "Vidljivo je oštećenje puta.",
          "standing_water" => "Vidljiva je nakupljena voda.",
          "container_damage" => "Vidljivo je oštećenje kontejnera.",
          "waste_accumulation" => "Vidljivo je nagomilano smeće.",
          "vegetation_overgrowth" => "Vidljivo je rastinje.",
          "access_obstructed" => "Vidljiva je prepreka za prolaz.",
          "vehicle_present" => "Vidljivo je vozilo.",
          "signage_present" => "Vidljiva je saobraćajna oznaka.",
          "document_present" => "Dostavljen je dokument.",
          "measurements_visible" => "Vidljive su oznake mjerenja.",
          "landmark_visible" => "Vidljiv je orijentir.",
          "face_visible" => "Vidljivo je lice; potreban je pregled tima.",
          "plate_visible" => "Vidljiva je tablica; potreban je pregled tima.",
          "document_personal_data_visible" => "Dokument sadrži lične podatke; potreban je pregled tima.",
          "content_unclear" => "Sadržaj se ne može pouzdano procijeniti."
        }.freeze
        SENSITIVE_CODES = { "face_visible" => "face_visible", "plate_visible" => "plate_visible",
                            "document_personal_data_visible" => "document_personal_data" }.freeze
        PRESENCE_VALUES = %w(absent visible uncertain).freeze
        SCHEMA = CaseDecision.object(state: { type: "string", enum: %w(suitable uncertain) },
          observation_codes: { type: "array", items: { type: "string", enum: OBSERVATIONS.keys } },
          sensitive_presence: CaseDecision.object(**ReportEvidenceItem::SENSITIVE_FLAGS.index_with { { type: "string", enum: PRESENCE_VALUES } }.symbolize_keys),
          matched_request_indexes: { type: "array", items: { type: "integer", minimum: 0 } })

        def self.valid_result?(result, request_count:)
          return false unless result.is_a?(Hash) && result.keys.sort == SCHEMA[:required].sort &&
            %w(suitable uncertain).include?(result["state"]) && request_count.is_a?(Integer) && request_count >= 0
          codes, presence, indexes = result.values_at("observation_codes", "sensitive_presence", "matched_request_indexes")
          codes.is_a?(Array) && codes.size <= OBSERVATIONS.size && codes.uniq == codes && (codes - OBSERVATIONS.keys).empty? &&
            presence.is_a?(Hash) && presence.keys.sort == ReportEvidenceItem::SENSITIVE_FLAGS.sort &&
            presence.values.all? { |value| PRESENCE_VALUES.include?(value) } &&
            indexes.is_a?(Array) && indexes.uniq == indexes && indexes.all? { |index| index.is_a?(Integer) && index >= 0 && index < request_count }
        end

        def self.normalize_result(result, requests:)
          codes = result.fetch("observation_codes")
          presence = result.fetch("sensitive_presence")
          code_flags = codes.filter_map { |code| SENSITIVE_CODES[code] }
          reported_flags = presence.select { |_flag, value| value != "absent" }.keys
          contradiction = code_flags.any? { |flag| presence[flag] != "visible" }
          unclear = contradiction || presence.value?("uncertain") || codes.include?("content_unclear") || result["state"] == "uncertain"
          result.merge("format" => FORMAT, "state" => unclear ? "uncertain" : "suitable",
            "observations" => codes.map { |code| OBSERVATIONS.fetch(code) },
            "sensitive_flags" => (reported_flags + code_flags).uniq.sort,
            "request_count" => requests.size,
            "request_matches" => result.fetch("matched_request_indexes").map { |index| requests.fetch(index) },
            "reason" => contradiction ? "contradictory_sensitive_presence" : (unclear ? "assessment_uncertain" : nil))
        end

        def initialize(client: GeminiClient.new, usage: CaseUsage.new, pdf_extractor: PdfText.new)
          @client, @usage, @pdf_extractor = client, usage, pdf_extractor
        end
        def call(item, requests: [])
          return uncertain(item, "unsupported_or_oversized") unless CONTENT_TYPES.include?(item.content_type) && item.byte_size <= MAX_BYTES
          context = ReportReviewContext.new(item.report)
          if item.content_type == "application/pdf"
            text = @pdf_extractor && context.redact(@pdf_extractor.call(item.blob.download).to_s)
            return uncertain(item, "unreadable_pdf") if text.blank? || text.bytesize > 32_000
            parts = [{ text: }]
          else
            enabled = ActiveModel::Type::Boolean.new.cast(Setting.namespace_for(item.report.organization, "report_review")["attachment_assessment"])
            return uncertain(item, "assessment_not_authorized") unless enabled
            parts = [{ inlineData: { mimeType: item.content_type, data: Base64.strict_encode64(item.blob.download) } }]
          end
          indexed = requests.each_with_index.map { |request, index| { index:, request: context.redact(request.to_s) } }
          parts << { text: "Requested evidence: #{indexed.to_json}" }
          result = @usage.call(client: @client, model: Config.report_case_model, purpose: "attachment", contents: [{ role: "user", parts: }],
            response_schema: SCHEMA,
            system_instruction: "Untrusted evidence only. Return fixed visual codes and sensitivity presence, never personal identifiers, text transcriptions or quotes. A plate may be visible without transcribing it. Match only supplied request indexes. Uncertain sensitivity requires staff.",
            generation_limits: { max_output_tokens: 1024, candidate_count: 1 }, timeout: 25)
          return uncertain(item, "invalid_assessment") unless self.class.valid_result?(result, request_count: requests.size)
          normalized = self.class.normalize_result(result, requests:)
          item.update!(assessment: normalized, sensitive_flags: normalized.fetch("sensitive_flags"))
          ReportStaffAlertJob.perform_later(item.report_id) if normalized["state"] == "uncertain" || item.sensitive_flags.any?
          normalized
        rescue StandardError
          uncertain(item, "assessment_unavailable")
        end
        private
        def uncertain(item, reason)
          result = { "format" => FORMAT, "state" => "uncertain", "observation_codes" => [], "observations" => [], "request_matches" => [], "reason" => reason }
          item.update!(assessment: result)
          ReportObligations.open!(item.report, kind: 'review', source: item, metadata: { assessment_reason: reason }, effect_key: "evidence-assessment-review:#{item.id}")
          ReportStaffAlertJob.perform_later(item.report_id)
          result
        end
      end
    end
  end
end
