# frozen_string_literal: true

require "test_helper"
require "decidim/bih"
require "support/decidim/bih/provider_fakes"

class DecidimBihProviderContractsTest < Minitest::Test
  def test_manifest_exposes_expected_contract_ids
    ids = Decidim::Bih::ProviderContracts.manifest.map { |contract| contract.fetch(:id) }

    assert_includes ids, "donations_provider"
    assert_includes ids, "city_data_freshness_provider"
    assert_includes ids, "city_data_preview_provider"
    assert_includes ids, "komsiluk_notice_public_source_provider"
    assert_includes ids, "admin_navigation_provider"
    assert_includes ids, "concierge_resolver"
    assert_includes ids, "geocoder_client"
    assert_includes ids, "infobip_client"
    assert_includes ids, "gemini_client"
    assert_includes ids, "odoo_client"
    assert_includes ids, "sistem48_forwarder"
    assert_includes ids, "sistem48_archive"
  end

  def test_method_validation_reports_missing_contract_methods
    error = assert_raises(Decidim::Bih::ProviderContracts::ContractError) do
      Decidim::Bih::ProviderContracts.validate_methods!("infobip_client", Object.new)
    end

    assert_includes error.message, "configured?"
    assert_includes error.message, "send_sms"
  end

  def test_infobip_contract_includes_launch_gated_session_reply_methods
    methods = Decidim::Bih::ProviderContracts.fetch("infobip_client").fetch(:required_methods)

    assert_includes methods, "chat_channel_configured?"
    assert_includes methods, "send_chat_text"
  end

  def test_validates_donation_provider_shape
    assert Decidim::Bih::ProviderContracts.validate_donations_provider!(
      Decidim::Bih::ProviderFakes::DonationProvider.new
    )
  end

  def test_validates_city_data_freshness_shape
    assert Decidim::Bih::ProviderContracts.validate_city_data_freshness_provider!(
      Decidim::Bih::ProviderFakes::CityDataFreshnessProvider.new,
      organization: "example.test"
    )
  end

  def test_disabled_city_data_source_has_no_refresh_command
    provider = Class.new do
      def statuses(organization: nil)
        [{ key: "service_source.heating_service", label: "Heating notices", status: "disabled",
           last_updated_on: nil, refresh_command: nil, detail: "disabled_by_owner" }]
      end
    end.new

    assert Decidim::Bih::ProviderContracts.validate_city_data_freshness_provider!(provider)
  end

  def test_active_city_data_source_still_requires_a_refresh_command
    provider = Class.new do
      def statuses(organization: nil)
        [{ key: "service_source.water_service", label: "Water notices", status: "warn",
           last_updated_on: nil, refresh_command: nil, detail: "source_unreachable" }]
      end
    end.new

    assert_raises(Decidim::Bih::ProviderContracts::ContractError) do
      Decidim::Bih::ProviderContracts.validate_city_data_freshness_provider!(provider)
    end
  end

  def test_validates_city_data_preview_shape
    assert Decidim::Bih::ProviderContracts.validate_city_data_preview_provider!(
      Decidim::Bih::ProviderFakes::CityDataPreviewProvider.new,
      organization: "example.test",
      locale: :sr
    )
  end

  def test_rejects_bad_city_data_preview_rows
    provider = Class.new do
      def previews(organization:, waste_query: nil, parking_query: nil, budget_query: nil, locale: :en)
        [
          {
            key: "waste",
            label: "Waste",
            query: waste_query.to_s,
            query_param: "city_waste_query",
            placeholder: "Area",
            source_url: nil,
            metadata: "organization=#{organization} parking=#{parking_query} budget=#{budget_query} locale=#{locale}",
            rows: [{ label: "Centar" }]
          }
        ]
      end
    end.new

    assert_raises(Decidim::Bih::ProviderContracts::ContractError) do
      Decidim::Bih::ProviderContracts.validate_city_data_preview_provider!(provider)
    end
  end

  def test_validates_admin_navigation_shape
    assert Decidim::Bih::ProviderContracts.validate_admin_navigation_provider!(
      Decidim::Bih::ProviderFakes::AdminNavigationProvider.new,
      view_context: Object.new
    )
  end

  def test_rejects_bad_admin_navigation_item_permissions
    provider = Class.new do
      def groups(view_context:)
        [
          {
            id: "daily",
            label: "Daily",
            items: [
              {
                id: "bad",
                label: "Bad",
                url: "/admin/bad",
                permission: Object.new,
                description: view_context.to_s
              }
            ]
          }
        ]
      end
    end.new

    assert_raises(Decidim::Bih::ProviderContracts::ContractError) do
      Decidim::Bih::ProviderContracts.validate_admin_navigation_provider!(provider, view_context: Object.new)
    end
  end

  def test_rejects_bad_city_data_status
    provider = Class.new do
      def statuses(organization: nil)
        [
          {
            key: "budget",
            label: "Budget",
            status: "maybe",
            last_updated_on: nil,
            refresh_command: "bin/refresh-city-data.sh",
            detail: organization.to_s
          }
        ]
      end
    end.new

    assert_raises(Decidim::Bih::ProviderContracts::ContractError) do
      Decidim::Bih::ProviderContracts.validate_city_data_freshness_provider!(provider)
    end
  end

  def test_validates_callable_concierge_resolver
    assert Decidim::Bih::ProviderContracts.validate_concierge_resolver!(
      -> { Decidim::Bih::ProviderFakes::ConciergeBrain.new }
    )
  end

  def test_fake_providers_expose_external_client_contracts
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "geocoder_client",
      Decidim::Bih::ProviderFakes::Geocoder
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "infobip_client",
      Decidim::Bih::ProviderFakes::InfobipClient.new
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "gemini_client",
      Decidim::Bih::ProviderFakes::GeminiClient.new
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "odoo_client",
      Decidim::Bih::ProviderFakes::OdooClient.new
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "sistem48_forwarder",
      Decidim::Bih::ProviderFakes::Sistem48Forwarder.new
    )
    assert Decidim::Bih::ProviderContracts.validate_methods!(
      "sistem48_archive",
      Decidim::Bih::ProviderFakes::Sistem48ArchiveScraper.new
    )
  end
end
