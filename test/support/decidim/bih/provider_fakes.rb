# frozen_string_literal: true

module Decidim
  module Bih
    module ProviderFakes
      DonationTotals = Struct.new(:total, :count, :currency, :as_of, keyword_init: true) # rubocop:disable Lint/StructNewOverride
      DonationProject = Struct.new(:title, :donate_url, :totals, keyword_init: true)

      class DonationProvider
        def totals
          DonationTotals.new(total: 10, count: 1, currency: "BAM", as_of: Time.now.utc)
        end

        def donate_url
          "https://donate.example.test"
        end

        def currency_label
          "KM"
        end

        def donation_presets
          [10, 25, 50]
        end

        def project_mappings
          [
            DonationProject.new(
              title: "Community project",
              donate_url: "https://donate.example.test/projects/community",
              totals: DonationTotals.new(total: 5, count: 1, currency: "BAM", as_of: Time.now.utc)
            )
          ]
        end
      end

      class CityDataFreshnessProvider
        def statuses(organization: nil)
          [
            {
              key: "budget",
              label: "Budget",
              status: "ok",
              last_updated_on: "2026-06-17",
              refresh_command: "bin/refresh-city-data.sh",
              detail: "line_items=1 organization=#{organization || "none"}"
            }
          ]
        end
      end

      class CityDataPreviewProvider
        def previews(organization:, waste_query: nil, parking_query: nil, budget_query: nil, locale: :en)
          [
            {
              key: "waste_schedule",
              label: "Waste schedule",
              query: waste_query.to_s,
              query_param: "city_waste_query",
              placeholder: "Area",
              source_url: "https://example.test/waste.pdf",
              metadata: "locale=#{locale} organization=#{organization || "none"} parking=#{parking_query} budget=#{budget_query}",
              rows: [
                { label: "Centar", value: "Monday" }
              ]
            }
          ]
        end
      end

      class AdminNavigationProvider
        def groups(view_context:)
          [
            {
              id: "daily",
              label: "Daily work",
              items: [
                {
                  id: "city_alerts",
                  label: "City alerts",
                  url: "/admin/bih/city-alerts",
                  description: "Review city-service events.",
                  permission: :integrations_read,
                  view_context_class: view_context.class.name
                }
              ]
            }
          ]
        end
      end

      class Geocoder
        def self.coordinates(address)
          new.coordinates(address)
        end

        def coordinates(address)
          return nil if address.to_s.strip.empty?

          { lat: 44.756, lon: 19.214 }
        end
      end

      class InfobipClient
        def configured?
          true
        end

        def viber_business_configured?
          true
        end

        def viber_bot_configured?
          true
        end

        def viber_bot_active?
          Decidim::Bih::Config.viber_bot_enabled? && viber_bot_configured?
        end

        def chat_channel_configured?(channel)
          %w(whatsapp messenger instagram).include?(channel.to_s)
        end

        def send_sms(to:, text:, from: nil)
          { to:, text:, from:, status: "accepted" }
        end

        def send_phone_message(to:, text:, viber_text: nil, viber_template: nil, expires_at: nil, messenger: nil, channels: nil, otp_code: nil) # rubocop:disable Metrics/ParameterLists
          {
            to:,
            text:,
            viber_text:,
            viber_template:,
            expires_at:,
            messenger:,
            channels:,
            otp_code:,
            status: "accepted"
          }
        end

        def send_viber(to:, text:, sender: nil, validity_period: nil, sms_failover: nil)
          { to:, text:, sender:, validity_period:, sms_failover:, status: "accepted" }
        end

        def send_viber_business(to:, text:, sender: nil, validity_period: nil, sms_failover: nil)
          { to:, text:, sender:, validity_period:, sms_failover:, status: "accepted" }
        end

        def send_viber_business_template(to:, template_id:, parameters:, language:, sender: nil, # rubocop:disable Metrics/ParameterLists
                                         validity_period: nil, sms_failover: nil)
          {
            to:, template_id:, parameters:, language:, sender:,
            validity_period:, sms_failover:, status: "accepted"
          }
        end

        def send_viber_bot(to:, text:, sender: nil)
          { to:, text:, sender:, status: "accepted" }
        end

        def send_viber_bot_image(to:, image_url:, text: nil, sender: nil)
          { to:, image_url:, text:, sender:, status: "accepted" }
        end

        def send_chat_text(channel:, to:, text:, sender: nil, request_phone: false)
          { channel:, to:, text:, sender:, request_phone:, status: "accepted" }
        end

        def send_viber_image(to:, image_url:, text: nil, sender: nil)
          { to:, image_url:, text:, sender:, status: "accepted" }
        end
      end

      class GeminiClient
        def configured?
          true
        end

        # rubocop:disable Metrics/ParameterLists -- mirror the production callable contract.
        def generate_content(
          contents:, response_schema: nil, model: nil, system_instruction: nil, timeout: nil, generation_limits: nil, retry_once: false
        )
          result = {
            "contents_count" => Array(contents).size,
            "schema_present" => !response_schema.nil?,
            "model" => model,
            "system_instruction" => system_instruction,
            "timeout" => timeout,
            "retry_once" => retry_once
          }
          result["generation_limits"] = generation_limits if generation_limits
          result
        end
        # rubocop:enable Metrics/ParameterLists
      end

      class OdooClient
        def configured?
          true
        end

        def read(_model, _domain = [], _fields = [], **_kwargs)
          []
        end

        def execute_kw(_model, _method, _args, _kwargs = {})
          []
        end
      end

      class Sistem48Forwarder
        attr_reader :last_error

        def call(_report)
          true
        end
      end

      class Sistem48ArchiveScraper
        def configured?
          true
        end

        def fetch_archive
          [{ reference: "20260001", status: "Prijava rijesena" }]
        end

        def parse(_html)
          fetch_archive
        end

        def status_for(reference:)
          fetch_archive.find { |entry| entry.fetch(:reference) == reference.to_s }
        end
      end

      class ConciergeBrain
        Reply = Struct.new(:text, keyword_init: true)

        def respond(message)
          Reply.new(text: message.respond_to?(:text) ? message.text : message.to_s)
        end
      end
    end
  end
end
