# frozen_string_literal: true

require "date"
require "json"
require "time"
require_relative "contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A deliberately small, non-prompted record of the last rendered civic
        # evidence. It is not a source cache and never contains answer text.
        module PriorEvidence
          VERSION = 1
          MAX_BYTES = 4096
          MAX_FACTS = 8
          IDENTIFIER = /\A[A-Za-z0-9][A-Za-z0-9:._-]{0,159}\z/
          AREA_SLUG = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,159}\z/
          PUBLIC_TOPICS = %w(waste water electricity transport parking heating roads city_service air_quality water_levels police sistem48 weather civil_protection bulky_waste
                             donation budget gazette volunteer participation community public_calls facilities rewards
                             health social_welfare agriculture permits education animals).freeze
          PUBLIC_NEIGHBORHOOD_SCOPES = %w(collected_public_service_notices collected_public_neighborhood_activity area_public_reports public_neighborhood_activities).freeze
          FACT_KEYS = %w(id source_id source_label checked_at observed_at reviewed_on source_published_at source_updated_at service_day starts_at ends_at valid_until).freeze
          SCOPE_KEYS = %w(area_slugs service_day starts_at ends_at).freeze
          KEYS = %w(version kind action topic status facts scope expires_at).freeze
          CIVIL_DATE = /\A\d{4}-\d{2}-\d{2}\z/
          RFC3339_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/

          module_function

          # rubocop:disable Metrics/ParameterLists
          def capture(result:, facts:, action:, topic:, now:, expires_at:)
            return unless %w(ok stale).include?(result.status) && allowed?(action, topic, result)
            return unless facts.is_a?(Array) && facts.any? && facts.length <= MAX_FACTS

            kind = member_board?(result) ? "member_board" : "public_read"
            value = {
              "version" => VERSION, "kind" => kind, "action" => action, "topic" => topic,
              "status" => result.status, "facts" => facts.map { |fact| capture_fact(fact, now) },
              "scope" => capture_scope(result, kind), "expires_at" => expires_at
            }
            normalize(value, now:, state_expires_at: expires_at)
          rescue Contracts::Invalid, ArgumentError, TypeError, KeyError
            nil
          end
          # rubocop:enable Metrics/ParameterLists

          # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          def normalize(value, now:, state_expires_at:)
            return nil if value.nil?

            item = Contracts.object!(value, KEYS)
            raise Contracts::Invalid, "Incomplete prior evidence" unless item.keys.sort == KEYS.sort
            raise Contracts::Invalid, "Unsupported prior evidence" unless item.fetch("version") == VERSION

            kind = Contracts.enum!(item.fetch("kind"), %w(public_read member_board))
            action = Contracts.enum!(item.fetch("action"), Contracts::ACTIONS)
            topic = Contracts.enum!(item.fetch("topic"), Contracts::TOPICS)
            raise Contracts::Invalid, "Invalid retained evidence operation" unless allowed_operation?(kind, action, topic)

            status = Contracts.enum!(item.fetch("status"), %w(ok stale))
            expires_at = numeric_time!(item.fetch("expires_at"), "evidence expiry")
            state_expiry = numeric_time!(state_expires_at, "state expiry")
            return nil if expires_at <= now.to_f
            raise Contracts::Invalid, "Evidence expiry exceeds state" unless expires_at <= state_expiry

            facts = normalize_facts(item.fetch("facts"), now:)
            scope = normalize_scope(item.fetch("scope"))
            raise Contracts::Invalid, "Member evidence area required" if kind == "member_board" && scope.fetch("area_slugs").length != 1

            normalized = { "version" => VERSION, "kind" => kind, "action" => action, "topic" => topic,
                           "status" => status, "facts" => facts, "scope" => scope, "expires_at" => expires_at }
            raise Contracts::Invalid, "Retained evidence exceeds size limit" if JSON.generate(normalized).bytesize > MAX_BYTES

            Contracts.snapshot(normalized)
          rescue KeyError
            raise Contracts::Invalid, "Incomplete prior evidence"
          end
          # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

          def allowed?(action, topic, result)
            return false unless action.is_a?(String) && topic.is_a?(String)
            if action == "ask_information" && topic == "neighborhood"
              return !member_board?(result) && result.coverage.is_a?(Hash) && PUBLIC_NEIGHBORHOOD_SCOPES.include?(result.coverage["scope"])
            end
            return true if action == "ask_information" && PUBLIC_TOPICS.include?(topic)
            return true if action == "choose_area" && topic == "neighborhood"

            action == "neighborhood_information" && topic == "neighborhood" && member_board?(result)
          end

          def allowed_operation?(kind, action, topic)
            return action == "neighborhood_information" && topic == "neighborhood" if kind == "member_board"

            # Only capture accepts a new public neighborhood result, with its
            # explicit public scope. Stored evidence keeps metadata, not access.
            (action == "ask_information" && (PUBLIC_TOPICS.include?(topic) || topic == "neighborhood")) ||
              (action == "choose_area" && topic == "neighborhood")
          end

          def member_board?(result)
            result.coverage.is_a?(Hash) && result.coverage["visibility"] == "member_board"
          end

          def capture_fact(fact, now)
            raise Contracts::Invalid, "Fact envelope required" unless fact.is_a?(Hash)

            # Read facts carry display URLs and other adapter-only fields. Take
            # the closed metadata projection rather than retaining or rejecting
            # an otherwise safe rendered fact because it had a URL.
            value = Contracts.object!(fact.slice(*FACT_KEYS), FACT_KEYS)
            source = value.fetch("source_id")
            captured = { "id" => stable!(value.fetch("id"), "fact identifier"), "source_id" => stable!(source, "source identifier") }
            label = value["source_label"]
            captured["source_label"] = safe_label!(label) unless label.nil?
            checked = value["checked_at"]
            captured["checked_at"] = past_time!(checked, "source check", now:) unless checked.nil?
            observed = value["observed_at"]
            captured["observed_at"] = past_date_or_time!(observed, "observation", now:) unless observed.nil?
            %w(reviewed_on source_published_at source_updated_at).each do |key|
              captured[key] = past_date_or_time!(value[key], key, now:) unless value[key].nil?
            end
            %w(service_day starts_at ends_at valid_until).each do |key|
              captured[key] = applicability_date!(value[key], key) unless value[key].nil?
            end
            captured
          end

          # rubocop:disable Metrics/CyclomaticComplexity
          def capture_scope(result, kind)
            coverage = result.coverage.is_a?(Hash) ? result.coverage : {}
            validity = result.validity.is_a?(Hash) ? result.validity : {}
            area_slugs = coverage["area_slugs"]
            area_slugs = [] if kind == "public_read" && area_slugs.nil?
            raise Contracts::Invalid, "Invalid evidence areas" unless area_slugs.is_a?(Array)

            scope = { "area_slugs" => area_slugs }
            if kind == "public_read" && (window = public_neighborhood_window(coverage))
              return scope.merge(window)
            end
            %w(service_day starts_at ends_at).each { |key| scope[key] = validity[key] || coverage[key] if validity[key] || coverage[key] }
            scope
          end
          # rubocop:enable Metrics/CyclomaticComplexity

          def public_neighborhood_window(coverage)
            case coverage["scope"]
            when "area_public_reports" then component_window(coverage["reports"])
            when "public_neighborhood_activities" then component_window(coverage["activities"])
            when "collected_public_neighborhood_activity"
              # The top-level window belongs to notices, not necessarily to
              # recent reports or upcoming activities. Never generalize it.
              windows = coverage.values_at("notices", "reports", "activities").select { |component| component.is_a?(Hash) }.map { |component| component_window(component) }
              complete = windows.all? { |window| window["starts_at"] && window["ends_at"] }
              complete && windows.uniq.one? ? windows.first : {}
            end
          end

          def component_window(component)
            component.is_a?(Hash) ? component.slice("service_day", "starts_at", "ends_at").compact : {}
          end

          def normalize_facts(value, now:)
            raise Contracts::Invalid, "Invalid retained facts" unless value.is_a?(Array) && value.length.between?(1, MAX_FACTS)

            seen = {}
            value.map do |fact|
              item = Contracts.object!(fact, FACT_KEYS)
              identifier = stable!(item.fetch("id"), "fact identifier")
              raise Contracts::Invalid, "Duplicate retained fact" if seen[identifier]

              seen[identifier] = true
              normalized = { "id" => identifier, "source_id" => stable!(item.fetch("source_id"), "source identifier") }
              normalized["source_label"] = safe_label!(item["source_label"]) unless item["source_label"].nil?
              normalize_fact_dates!(normalized, item, now:)
              normalized
            end
          end

          def normalize_fact_dates!(normalized, item, now:)
            normalized["checked_at"] = past_time!(item["checked_at"], "source check", now:) unless item["checked_at"].nil?
            normalized["observed_at"] = past_date_or_time!(item["observed_at"], "observation", now:) unless item["observed_at"].nil?
            %w(reviewed_on source_published_at source_updated_at).each do |key|
              normalized[key] = past_date_or_time!(item[key], key, now:) unless item[key].nil?
            end
            %w(service_day starts_at ends_at valid_until).each { |key| normalized[key] = applicability_date!(item[key], key) unless item[key].nil? }
          end

          def normalize_scope(value)
            item = Contracts.object!(value, SCOPE_KEYS)
            slugs = item.fetch("area_slugs")
            raise Contracts::Invalid, "Invalid evidence areas" unless slugs.is_a?(Array) && slugs.length <= MAX_FACTS

            normalized_slugs = slugs.map { |slug| area_slug!(slug) }
            raise Contracts::Invalid, "Duplicate evidence area" unless normalized_slugs.uniq.length == normalized_slugs.length

            normalized = { "area_slugs" => normalized_slugs }
            %w(service_day starts_at ends_at).each { |key| normalized[key] = applicability_date!(item[key], key) unless item[key].nil? }
            normalized
          end

          def stable!(value, label)
            text = Contracts.text!(value, limit: 160)
            raise Contracts::Invalid, "Invalid #{label}" unless text.match?(IDENTIFIER)

            text
          end

          def area_slug!(value)
            text = Contracts.text!(value, limit: 160)
            raise Contracts::Invalid, "Invalid evidence area" unless text.match?(AREA_SLUG)

            text
          end

          def safe_label!(value)
            text = Contracts.text!(value, limit: 160)
            unsafe = %r{(?:\b[a-z][a-z0-9+.-]*:(?://|[^\s])|\bwww\.)}i
            credential = /\b(?:token|password|lozinka|šifra|sifra|otp|kod|код)\b/i
            raise Contracts::Invalid, "Unsafe evidence label" if text.match?(/[\x00-\x1f]/) || text.match?(unsafe) || text.match?(credential)

            text
          end

          def numeric_time!(value, label)
            raise Contracts::Invalid, "Invalid #{label}" unless value.is_a?(Numeric) && !value.is_a?(Complex)

            number = value.to_f
            raise Contracts::Invalid, "Invalid #{label}" unless number.finite? && number.positive?

            number
          rescue TypeError, ArgumentError
            raise Contracts::Invalid, "Invalid #{label}"
          end

          def past_time!(value, label, now:)
            text = value.is_a?(Time) ? nil : Contracts.text!(value, limit: 40)
            raise Contracts::Invalid, "Invalid #{label}" if text && !text.match?(RFC3339_TIME)

            time = value.is_a?(Time) ? value : Time.iso8601(text)
            raise Contracts::Invalid, "Invalid #{label}" if text && time.to_date.iso8601 != text[0, 10]
            raise Contracts::Invalid, "Future #{label}" if time > now

            time.getutc.iso8601
          rescue ArgumentError, TypeError
            raise Contracts::Invalid, "Invalid #{label}"
          end

          def past_date_or_time!(value, label, now:)
            return past_time!(value, label, now:) if value.is_a?(Time) || value.to_s.include?("T")

            text = Contracts.text!(value, limit: 10)
            raise Contracts::Invalid, "Invalid #{label}" unless text.match?(CIVIL_DATE)

            date = Date.iso8601(text)
            raise Contracts::Invalid, "Future #{label}" if date > now.to_date

            date.iso8601
          rescue ArgumentError, TypeError
            raise Contracts::Invalid, "Invalid #{label}"
          end

          def applicability_date!(value, label)
            return value.getutc.iso8601 if value.is_a?(Time)

            text = Contracts.text!(value, limit: 40)
            unless text.include?("T")
              raise Contracts::Invalid, "Invalid #{label}" unless text.match?(CIVIL_DATE)

              date = Date.iso8601(text)
              raise Contracts::Invalid, "Invalid #{label}" unless date.iso8601 == text

              return date.iso8601
            end

            raise Contracts::Invalid, "Invalid #{label}" unless text.match?(RFC3339_TIME)

            time = Time.iso8601(text)
            raise Contracts::Invalid, "Invalid #{label}" unless time.to_date.iso8601 == text[0, 10]

            time.getutc.iso8601
          rescue ArgumentError, TypeError
            raise Contracts::Invalid, "Invalid #{label}"
          end
        end
      end
    end
  end
end
