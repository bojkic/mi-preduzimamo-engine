# frozen_string_literal: true

require "date"
require "json"
require "uri"
require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Public tool evidence, never provider-supplied authority. Eligibility is
        # checked against the host registry both before prompting and before send.
        class EvidenceEnvelope
          STATUSES = %w(ok empty ambiguous unsupported unavailable unreviewed expired conflicting not_authorized).freeze
          RECORD_FIELDS = %w(id document_id revision text facts source_url source_locator published_at observed_at valid_from valid_until review_expires_at coverage
                             limitations).freeze
          REQUIRED_FIELDS = %w(id document_id revision text).freeze
          CANDIDATE_REQUIRED_FIELDS = %w(id document_id revision label).freeze
          CANDIDATE_FIELDS = (CANDIDATE_REQUIRED_FIELDS + %w(selection_key)).freeze
          SCOPE_FIELDS = %w(operation subject_ids source_ids area_ids date window_start window_end reason_code search_complete resolved_query).freeze
          TRANSPORT_REASONS = %w(unresolved_place unsupported_calendar source_unavailable incomplete_search no_eligible_trip_in_reviewed_scope).freeze
          RESOLVED_QUERY_FIELDS = %w(version origin_ids destination_ids date after_time timezone mode route_code direction direct_only radius_meters transfer_limit origin_resolution destination_resolution).freeze
          RESOLUTION_KINDS = %w(supplied_stop assumed_area consented_current_location).freeze
          MAX_BYTES = 524_288

          attr_reader :organization_id, :registry_epoch, :status, :evidence, :candidates, :warnings, :coverage_complete, :query_scope

          # Explicit fields keep source status and coverage distinct.
          def initialize(organization_id:, registry_epoch:, status:, evidence: [], candidates: [], warnings: [], coverage_complete: false, query_scope: {}) # rubocop:disable Metrics/ParameterLists
            validate_header!(organization_id, evidence, candidates, warnings, coverage_complete)
            @organization_id = organization_id
            @registry_epoch = Contracts.text!(registry_epoch, limit: 128)
            raise Contracts::Invalid, "Registry epoch required" if @registry_epoch.empty?

            @status = Contracts.enum!(status, STATUSES)
            validate_status!(evidence, coverage_complete)
            @evidence = immutable(evidence.map { |record| validate_record(record) })
            raise Contracts::Invalid, "Duplicate evidence IDs" unless @evidence.map { |record| record.fetch("id") }.uniq.size == @evidence.size

            @candidates = immutable(candidates.map { |candidate| validate_candidate(candidate) })
            @warnings = validated_warnings(warnings)
            @query_scope = validated_query_scope(query_scope)
            raise Contracts::Invalid, "Complete query scope required" if coverage_complete && @query_scope.empty?

            @coverage_complete = coverage_complete
            raise Contracts::Invalid, "Evidence payload exceeded" if JSON.generate(prompt_data).bytesize > MAX_BYTES

            freeze
          end

          private def validated_warnings(warnings)
            warnings.map do |warning|
              raise Contracts::Invalid, "Public warning code required" unless warning.is_a?(String) && warning.match?(/\A[a-z][a-z0-9_]{0,79}\z/)

              warning.dup.freeze
            end.freeze
          end

          # The policy receives the current trusted clock and current registry.
          # Repeating this method at send time rechecks even an already-built prompt.
          def for_prompt(context:, eligibility:)
            validate_context!(context)
            raise Contracts::Invalid, "Evidence policy required" unless eligibility.respond_to?(:call)

            # A nil record checks current registry/query scope even for a zero
            # result. Neither empty evidence nor disambiguation bypasses policy.
            eligible = [nil, *evidence, *candidates].all? do |record|
              eligibility.call(record: record, organization_id: organization_id, registry_epoch: registry_epoch, now: context.now, query_scope: query_scope) == true
            end
            raise Contracts::Invalid, "Evidence no longer eligible" unless eligible

            raise Contracts::Invalid, "Evidence deadline expired" if context.deadline.expired?

            prompt_data
          end

          private

          def validate_context!(context)
            scoped = context.is_a?(Contracts::TrustedContext) && context.organization_id == organization_id && context.allows?("public_reads")
            raise Contracts::Invalid, "Public trusted scope required" unless scoped
            raise Contracts::Invalid, "Evidence deadline expired" if context.deadline.nil? || context.deadline.expired?
          end

          def validate_header!(organization_id, evidence, candidates, warnings, coverage_complete)
            raise Contracts::Invalid, "Evidence organization required" unless organization_id.is_a?(Integer) && organization_id.positive?
            raise Contracts::Invalid, "Coverage flag must be boolean" unless [true, false].include?(coverage_complete)

            [evidence, candidates, warnings].each do |items|
              raise Contracts::Invalid, "Bounded evidence collections required" unless items.is_a?(Array) && items.size <= 512
            end
            measure_payload!([evidence, candidates, warnings])
          end

          # Check raw structure before copying strings or building serialized JSON.
          def measure_payload!(value, budget = [MAX_BYTES, 4096], depth = 0)
            budget[1] -= 1
            raise Contracts::Invalid, "Evidence structure exceeded" if depth > 10 || budget[1].negative?

            case value
            when Hash
              value.each do |key, item|
                measure_payload!(key, budget, depth + 1)
                measure_payload!(item, budget, depth + 1)
              end
            when Array then value.each { |item| measure_payload!(item, budget, depth + 1) }
            when String then budget[0] -= value.bytesize
            end
            raise Contracts::Invalid, "Evidence payload exceeded" if budget[0].negative?
          end

          def validate_status!(evidence, coverage_complete)
            raise Contracts::Invalid, "Failure cannot assert evidence" unless %w(ok conflicting).include?(@status) || evidence.empty?
            raise Contracts::Invalid, "Empty status requires complete coverage" if @status == "empty" && !coverage_complete
          end

          def prompt_data
            { "status" => status, "evidence" => evidence, "candidates" => candidates,
              "warnings" => warnings, "coverage_complete" => coverage_complete, "registry_epoch" => registry_epoch, "query_scope" => query_scope }.freeze
          end

          def validated_query_scope(scope)
            fields = Contracts.object!(scope, SCOPE_FIELDS)
            fields.each do |name, value|
              case name
              when "search_complete"
                raise Contracts::Invalid, "Search completion must be boolean" unless [true, false].include?(value)
              when "reason_code"
                raise Contracts::Invalid, "Invalid transport reason" unless TRANSPORT_REASONS.include?(value)
              when "resolved_query"
                validate_resolved_query!(value)
              else
                values = name.end_with?("_ids") ? value : [value]
                raise Contracts::Invalid, "Public query scope values required" unless values.is_a?(Array) && values.size <= 40

                values.each { |item| Contracts.text!(item, limit: 160) }
              end
            end
            Contracts.snapshot(fields)
          end

          def validate_resolved_query!(raw)
            query = Contracts.object!(raw, RESOLVED_QUERY_FIELDS)
            raise Contracts::Invalid, "Invalid resolved query version" unless query["version"] == 1
            raise Contracts::Invalid, "Resolved query too large" if JSON.generate(query).bytesize > 3_000

            %w(origin_ids destination_ids).each do |key|
              ids = query.fetch(key, [])
              raise Contracts::Invalid, "Invalid resolved stop IDs" unless ids.is_a?(Array) && ids.size <= 40 && ids.uniq == ids

              ids.each { |id| Contracts.text!(id, limit: 128) }
            end
            if query["date"]
              value = Contracts.text!(query["date"], limit: 10)
              raise Contracts::Invalid, "Invalid resolved service date" unless Date.iso8601(value).iso8601 == value
            end
            if query["after_time"]
              raise Contracts::Invalid, "Invalid resolved time" unless query["after_time"].is_a?(String) &&
                query["after_time"].match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
            end
            raise Contracts::Invalid, "Invalid resolved timezone" if query["timezone"] && query["timezone"] != "Europe/Sarajevo"
            raise Contracts::Invalid, "Invalid resolved mode" if query["mode"] && !%w(fastest next last arrive_by).include?(query["mode"])
            raise Contracts::Invalid, "Invalid resolved route" if query["route_code"] && !(query["route_code"].is_a?(String) && query["route_code"].match?(/\A[GP][1-9]\d?\z/))
            raise Contracts::Invalid, "Invalid resolved direction" if query["direction"] && !%w(A B).include?(query["direction"])
            raise Contracts::Invalid, "Invalid direct-only option" if query.key?("direct_only") && ![true, false].include?(query["direct_only"])
            raise Contracts::Invalid, "Invalid walking radius" if query["radius_meters"] && !query["radius_meters"].is_a?(Integer)
            raise Contracts::Invalid, "Invalid walking radius" if query["radius_meters"] && !query["radius_meters"].between?(0, 3_000)
            raise Contracts::Invalid, "Invalid transfer limit" if query["transfer_limit"] && !query["transfer_limit"].is_a?(Integer)
            raise Contracts::Invalid, "Invalid transfer limit" if query["transfer_limit"] && !query["transfer_limit"].between?(0, 2)
            %w(origin_resolution destination_resolution).each do |key|
              raise Contracts::Invalid, "Invalid place resolution" if query[key] && !RESOLUTION_KINDS.include?(query[key])
            end
            query
          rescue Date::Error, JSON::GeneratorError
            raise Contracts::Invalid, "Invalid resolved query"
          end

          def validate_candidate(candidate)
            value = Contracts.object!(candidate, CANDIDATE_FIELDS)
            raise Contracts::Invalid, "Candidate provenance required" unless (CANDIDATE_REQUIRED_FIELDS - value.keys).empty?

            value.each_value do |item|
              Contracts.text!(item, limit: 160)
              raise Contracts::Invalid, "Candidate value required" if item.empty?
            end
            value
          end

          def validate_record(record)
            value = Contracts.object!(record, RECORD_FIELDS)
            raise Contracts::Invalid, "Incomplete evidence identity" unless (REQUIRED_FIELDS - value.keys).empty?

            %w(id document_id revision).each do |key|
              value[key] = Contracts.text!(value.fetch(key), limit: 160)
              raise Contracts::Invalid, "Empty evidence identity" if value[key].empty?
            end
            Contracts.text!(value.fetch("text"), limit: 100_000)
            if value["source_url"]
              uri = URI.parse(value.fetch("source_url"))
              raise Contracts::Invalid, "Public HTTPS source required" unless uri.scheme == "https" && uri.host && !uri.userinfo
            end
            value
          rescue URI::InvalidURIError
            raise Contracts::Invalid, "Invalid evidence source"
          end

          # Each JSON type is validated here before recursive freezing.
          def immutable(value, depth = 0) # rubocop:disable Metrics/CyclomaticComplexity
            raise Contracts::Invalid, "Evidence nesting exceeded" if depth > 10

            case value
            when Hash
              raise Contracts::Invalid, "Evidence object exceeded" if value.size > 128

              normalized = value.to_h { |key, item| [Contracts.text!(key.to_s, limit: 128), immutable(item, depth + 1)] }
              raise Contracts::Invalid, "Duplicate evidence fields" unless normalized.size == value.size

              normalized.freeze
            when Array
              raise Contracts::Invalid, "Evidence collection exceeded" if value.size > 512

              value.map { |item| immutable(item, depth + 1) }.freeze
            when String then Contracts.text!(value, limit: 100_000)
            when Integer, TrueClass, FalseClass, NilClass then value
            when Float
              raise Contracts::Invalid, "Non-finite evidence" unless value.finite?

              value
            else raise Contracts::Invalid, "Unsupported evidence value"
            end
          end
        end
      end
    end
  end
end
