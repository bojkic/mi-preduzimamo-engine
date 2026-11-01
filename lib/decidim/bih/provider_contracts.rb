# frozen_string_literal: true

require "active_support/core_ext/hash/keys"
require "active_support/core_ext/object/blank"

module Decidim
  module Bih
    # Machine-readable interface contracts for host-wired providers and external
    # clients. These checks are intentionally shallow: they prove method/shape
    # compatibility without sending live provider requests or requiring secrets.
    module ProviderContracts
      ContractError = Class.new(StandardError)

      CONTRACTS = [
        {
          id: "donations_provider",
          setting: "Decidim::Bih.donations_provider",
          required_methods: %w(totals donate_url currency_label),
          optional_methods: %w(project_mappings donation_presets refresh! refresh_all! refresh_job_args),
          description: "Host donation aggregate provider consumed by public donation, impact, analytics, and concierge surfaces."
        },
        {
          id: "city_data_freshness_provider",
          setting: "Decidim::Bih.city_data_freshness_provider",
          required_methods: %w(statuses),
          optional_methods: [],
          description: "Host read-only city-data freshness rows shown in operator integrations and ops health output."
        },
        {
          id: "city_data_preview_provider",
          setting: "Decidim::Bih.city_data_preview_provider",
          required_methods: %w(previews),
          optional_methods: [],
          description: "Host admin-only city-data preview rows for checked-in datasets exposed through the platform assistant."
        },
        {
          id: "komsiluk_board_context_provider",
          setting: "Decidim::Bih.komsiluk_board_context_provider",
          required_methods: %w(call),
          optional_methods: [],
          description: "Host read-only canonical service/context links for an already authorized board member. No record publication or phone delivery."
        },
        {
          id: "komsiluk_notice_public_source_provider",
          setting: "Decidim::Bih.komsiluk_notice_public_source_provider",
          required_methods: %w(call),
          optional_methods: [],
          description: "Citizen-safe current source path and material-update state for linked staff notices and city-service notices requiring source revalidation (including legacy severe weather). Missing provider fails closed."
        },
        {
          id: "komsiluk_notice_source_provider",
          setting: "Decidim::Bih::Komsiluk::NoticeComposer.source_provider",
          required_methods: %w(call),
          optional_methods: %w(with_source_lock with_reviewed_source_lock refresh_due!),
          description: "Resolve approved public record references into board drafts and revalidate exact source revisions at confirmation and dispatch."
        },
        {
          id: "admin_navigation_provider",
          setting: "Decidim::Bih.admin_navigation_provider",
          required_methods: %w(groups),
          optional_methods: [],
          description: "Host admin navigation groups merged into the BIH operator hub and filtered by permissions."
        },
        {
          id: "concierge_resolver",
          setting: "Decidim::Bih.concierge_resolver",
          required_methods: %w(respond),
          optional_methods: [],
          description: "Host web-chat resolver binding the generic concierge responder to local data sources."
        },
        {
          id: "geocoder_client",
          setting: "Decidim::Bih::Geo::Geocoder",
          required_methods: %w(coordinates),
          optional_methods: [],
          description: "Nominatim-compatible geocoder client returning transient lat/lon hashes without storing addresses."
        },
        {
          id: "infobip_client",
          setting: "Decidim::Bih::Infobip::Client",
          required_methods: %w(configured? viber_business_configured? viber_bot_configured? viber_bot_active?
                               send_phone_message send_sms
                               send_viber_business send_viber_business_template send_viber_bot send_viber_bot_image
                               chat_channel_configured? send_chat_text),
          optional_methods: [],
          description: "Infobip ordered phone delivery, Viber transports, and launch-gated immediate-session chat replies."
        },
        {
          id: "gemini_client",
          setting: "Decidim::Bih::Ai::GeminiClient",
          required_methods: %w(configured? generate_content),
          optional_methods: [],
          description: "Gemini/Vertex client used by report and concierge intent classification."
        },
        {
          id: "odoo_client",
          setting: "Decidim::Bih::Odoo::Client",
          required_methods: %w(configured? read execute_kw),
          optional_methods: %w(uid),
          description: "Odoo JSON-RPC client used by donation and future finance-grade integrations."
        },
        {
          id: "sistem48_forwarder",
          setting: "Decidim::Bih::Sistem48::Forwarder",
          required_methods: %w(call),
          optional_methods: %w(last_error),
          description: "Sistem 48 forwarding adapter used by report-processing retry workflows."
        },
        {
          id: "sistem48_archive",
          setting: "Decidim::Bih::Sistem48::ArchiveScraper",
          required_methods: %w(configured? fetch_archive parse status_for),
          optional_methods: [],
          description: "Sistem 48 public archive adapter used by status synchronization."
        }
      ].freeze

      CITY_DATA_STATUS_VALUES = %w(ok warn fail disabled).freeze
      CITY_DATA_ROW_KEYS = [:key, :label, :status, :last_updated_on, :refresh_command, :detail].freeze
      CITY_DATA_PREVIEW_KEYS = [:key, :label, :query, :query_param, :placeholder, :source_url, :metadata, :rows].freeze
      CITY_DATA_PREVIEW_ROW_KEYS = [:label, :value].freeze
      DONATION_TOTAL_KEYS = [:total, :count, :currency, :as_of].freeze
      ADMIN_NAVIGATION_GROUP_KEYS = [:id, :label, :items].freeze
      ADMIN_NAVIGATION_ITEM_KEYS = [:id, :label, :url].freeze

      class << self
        def manifest
          CONTRACTS.map { |contract| contract.transform_values { |value| value.is_a?(Array) ? value.dup : value } }
        end

        def fetch(id)
          contract = CONTRACTS.find { |candidate| candidate.fetch(:id) == id.to_s }
          raise KeyError, "unknown provider contract: #{id}" unless contract

          contract
        end

        def validate_methods!(id, object)
          missing = missing_methods(id, object)
          return true if missing.empty?

          raise ContractError, "#{id} missing required methods: #{missing.join(", ")}"
        end

        def missing_methods(id, object)
          contract = fetch(id)
          contract.fetch(:required_methods).reject { |method_name| object.respond_to?(method_name) }
        end

        def validate_donations_provider!(provider)
          validate_methods!("donations_provider", provider)

          validate_donation_totals!(provider.totals)
          validate_optional_string!(provider.donate_url, "donations_provider.donate_url")
          validate_optional_string!(provider.currency_label, "donations_provider.currency_label")
          validate_project_mappings!(provider.project_mappings) if provider.respond_to?(:project_mappings)
          true
        end

        def validate_city_data_freshness_provider!(provider, organization: nil)
          validate_methods!("city_data_freshness_provider", provider)

          rows = provider.statuses(organization:)
          raise ContractError, "city_data_freshness_provider.statuses must return an Array" unless rows.is_a?(Array)

          rows.each { |row| validate_city_data_row!(row) }
          true
        end

        def validate_city_data_preview_provider!(provider, organization: nil, locale: nil)
          validate_methods!("city_data_preview_provider", provider)

          previews = provider.previews(
            organization:,
            waste_query: nil,
            parking_query: nil,
            budget_query: nil,
            locale: locale || :en
          )
          raise ContractError, "city_data_preview_provider.previews must return an Array" unless previews.is_a?(Array)

          previews.each { |preview| validate_city_data_preview!(preview) }
          true
        end

        def validate_admin_navigation_provider!(provider, view_context:)
          validate_methods!("admin_navigation_provider", provider)

          groups = provider.groups(view_context:)
          raise ContractError, "admin_navigation_provider.groups must return an Array" unless groups.is_a?(Array)

          groups.each { |group| validate_admin_navigation_group!(group) }
          true
        end

        def validate_concierge_resolver!(resolver)
          object = resolver.respond_to?(:call) ? resolver.call : resolver
          validate_methods!("concierge_resolver", object)
        end

        private

        def validate_donation_totals!(totals)
          missing = DONATION_TOTAL_KEYS.reject { |method_name| totals.respond_to?(method_name) }
          return if missing.empty?

          raise ContractError, "donation totals missing methods: #{missing.join(", ")}"
        end

        def validate_project_mappings!(mappings)
          Array(mappings).each do |mapping|
            [:title, :donate_url, :totals].each do |method_name|
              raise ContractError, "donation project mapping missing method: #{method_name}" unless mapping.respond_to?(method_name)
            end
            validate_optional_string!(mapping.title, "donation project title")
            validate_optional_string!(mapping.donate_url, "donation project donate_url")
            validate_donation_totals!(mapping.totals)
          end
        end

        def validate_city_data_row!(row)
          raise ContractError, "city-data freshness row must be Hash-like" unless row.respond_to?(:to_h)

          normalized = row.to_h.symbolize_keys
          missing = CITY_DATA_ROW_KEYS.reject { |key| normalized.has_key?(key) }
          raise ContractError, "city-data freshness row missing keys: #{missing.join(", ")}" if missing.any?

          validate_required_string!(normalized[:key], "city-data freshness key")
          validate_required_string!(normalized[:label], "city-data freshness label")
          if normalized[:status].to_s == "disabled"
            validate_optional_string!(normalized[:refresh_command], "city-data freshness refresh_command")
          else
            validate_required_string!(normalized[:refresh_command], "city-data freshness refresh_command")
          end
          validate_optional_string!(normalized[:detail], "city-data freshness detail")
          return if CITY_DATA_STATUS_VALUES.include?(normalized[:status].to_s)

          raise ContractError, "city-data freshness status must be one of #{CITY_DATA_STATUS_VALUES.join(", ")}"
        end

        def validate_city_data_preview!(preview)
          raise ContractError, "city-data preview must be Hash-like" unless preview.respond_to?(:to_h)

          normalized = preview.to_h.symbolize_keys
          missing = CITY_DATA_PREVIEW_KEYS.reject { |key| normalized.has_key?(key) }
          raise ContractError, "city-data preview missing keys: #{missing.join(", ")}" if missing.any?

          validate_required_string!(normalized[:key], "city-data preview key")
          validate_required_string!(normalized[:label], "city-data preview label")
          validate_optional_string!(normalized[:query], "city-data preview query")
          validate_required_string!(normalized[:query_param], "city-data preview query_param")
          validate_optional_string!(normalized[:placeholder], "city-data preview placeholder")
          validate_optional_string!(normalized[:source_url], "city-data preview source_url")
          validate_optional_string!(normalized[:metadata], "city-data preview metadata")
          raise ContractError, "city-data preview rows must be an Array" unless normalized[:rows].is_a?(Array)

          normalized[:rows].each { |row| validate_city_data_preview_row!(row) }
        end

        def validate_city_data_preview_row!(row)
          raise ContractError, "city-data preview row must be Hash-like" unless row.respond_to?(:to_h)

          normalized = row.to_h.symbolize_keys
          missing = CITY_DATA_PREVIEW_ROW_KEYS.reject { |key| normalized.has_key?(key) }
          raise ContractError, "city-data preview row missing keys: #{missing.join(", ")}" if missing.any?

          validate_required_string!(normalized[:label], "city-data preview row label")
          validate_required_string!(normalized[:value], "city-data preview row value")
        end

        def validate_admin_navigation_group!(group)
          raise ContractError, "admin navigation group must be Hash-like" unless group.respond_to?(:to_h)

          normalized = group.to_h.symbolize_keys
          missing = ADMIN_NAVIGATION_GROUP_KEYS.reject { |key| normalized.has_key?(key) }
          raise ContractError, "admin navigation group missing keys: #{missing.join(", ")}" if missing.any?

          validate_required_string!(normalized[:id], "admin navigation group id")
          validate_required_string!(normalized[:label], "admin navigation group label")
          raise ContractError, "admin navigation group items must be an Array" unless normalized[:items].is_a?(Array)

          normalized[:items].each { |item| validate_admin_navigation_item!(item) }
        end

        def validate_admin_navigation_item!(item)
          raise ContractError, "admin navigation item must be Hash-like" unless item.respond_to?(:to_h)

          normalized = item.to_h.symbolize_keys
          missing = ADMIN_NAVIGATION_ITEM_KEYS.reject { |key| normalized.has_key?(key) }
          raise ContractError, "admin navigation item missing keys: #{missing.join(", ")}" if missing.any?

          validate_required_string!(normalized[:id], "admin navigation item id")
          validate_required_string!(normalized[:label], "admin navigation item label")
          validate_required_string!(normalized[:url], "admin navigation item url")
          validate_optional_string!(normalized[:description], "admin navigation item description")
          return if normalized[:permission].nil? || normalized[:permission].is_a?(String) || normalized[:permission].is_a?(Symbol)

          raise ContractError, "admin navigation item permission must be a String, Symbol, or nil"
        end

        def validate_required_string!(value, label)
          return if value.is_a?(String) && value.present?

          raise ContractError, "#{label} must be a non-empty String"
        end

        def validate_optional_string!(value, label)
          return if value.nil? || value.is_a?(String)

          raise ContractError, "#{label} must be a String or nil"
        end
      end
    end
  end
end
