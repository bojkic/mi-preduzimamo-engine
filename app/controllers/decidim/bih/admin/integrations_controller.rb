# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.5) — read-only integrations health/status page.
      #
      # Shows, per external integration (Gemini, Odoo, Infobip omnichannel
      # [Viber + SMS], SMTP), whether it is CONFIGURED — derived purely from
      # Decidim::Bih::Config presence checks and a couple of host ENV vars for
      # SMTP. It NEVER prints a secret value: only "configured: yes/no" and, when
      # partial/unconfigured, which ENV var names are still missing.
      #
      # Permission model: mirrors every other Bih admin controller — gated on
      # current_user.admin? via ApplicationController#ensure_global_admin!.
      #
      # LIVE STATE: the engine instruments integration calls via
      # Decidim::Bih::Instrumentation (ActiveSupport::Notifications). A durable,
      # Redis-backed subscriber (Decidim::Bih::IntegrationHealth, installed from
      # the engine) folds those metadata-only events into a small per-provider
      # health record. This page now shows, alongside the static config-presence
      # check, the live last-OK / last-error state read back from that subscriber.
      class IntegrationsController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:integrations_read) }

        # Declarative description of each integration row: the i18n key suffix,
        # the source it reads from, and the ENV var names that back the required
        # keys (used to tell the operator which var is missing — names only,
        # never values).
        PROVIDERS = [
          {
            key: "gemini",
            config: :gemini,
            required: { api_key: "GEMINI_API_KEY" }
          },
          {
            key: "odoo",
            config: :odoo,
            required: {
              base_url: "ODOO_URL",
              db: "ODOO_DB",
              login: "ODOO_LOGIN",
              api_key: "ODOO_API_KEY"
            }
          },
          {
            key: "infobip",
            config: :infobip,
            required: {
              base_url: "INFOBIP_BASE_URL",
              api_key: "INFOBIP_API_KEY"
            }
          }
        ].freeze

        # Maps each status row (keyed by the view's provider key) to the
        # Decidim::Bih::Instrumentation provider bucket(s) whose live health it
        # reflects. SMTP delivery has no client of its own; it is exercised by
        # the Sistem 48 forwarder (which deliver_now!s an email), so its row
        # mirrors the sistem48 bucket.
        HEALTH_BUCKETS = {
          "gemini" => %w(gemini),
          "odoo" => %w(odoo),
          "infobip" => %w(infobip),
          "smtp" => %w(sistem48)
        }.freeze

        # GET /admin/bih/integrations
        def index
          @statuses = PROVIDERS.map { |spec| config_status(spec) }
          @statuses << smtp_status
          @statuses.each { |status| status[:health] = live_health(status[:key]) }
          @city_data_statuses = city_data_statuses
          @city_data_previews = city_data_previews
          # Gemini "configured but misrouted" degraded state — surfaced as a
          # banner. Reuses Config's single source of truth so it can never drift
          # from the boot-time warning.
          @gemini_misrouted = Decidim::Bih::Config.gemini_misrouted?
        end

        private

        # Reads the durable subscriber's per-provider state for a status row,
        # merging the buckets that feed it (org-scoped first, then global, so a
        # tenant-specific event wins). Returns a normalised hash the view colours
        # on; never raises (IntegrationHealth#state is itself fully rescued).
        def live_health(row_key)
          buckets = HEALTH_BUCKETS.fetch(row_key, [])
          health = Decidim::Bih::IntegrationHealth.instance
          states = buckets.flat_map do |provider|
            # Most provider clients are organization-agnostic and record under the
            # "global" bucket; report-driven ones (sistem48) carry an org id. Read
            # BOTH and let merge_health pick the most informative.
            [
              health.state(provider:, organization_id: current_organization&.id),
              health.state(provider:)
            ]
          end
          merge_health(states)
        end

        # Picks the most informative state across a row's buckets: prefer a
        # current failure, then a current success, then stale evidence, else
        # unknown — and carry the matching
        # timestamps/error metadata for the view.
        def merge_health(states)
          return blank_health if states.empty?

          states.find { |s| s[:status] == :failing } ||
            states.find { |s| s[:status] == :ok } ||
            states.find { |s| s[:status] == :stale } ||
            states.first || blank_health
        end

        def blank_health
          { status: :unknown, last_success_at: nil, last_error_at: nil,
            last_error_code: nil, last_error_class: nil, success_count: 0, failure_count: 0 }
        end

        # Builds a status row from a Decidim::Bih::Config-backed provider. A
        # provider is "configured" only when every required key is present;
        # otherwise it reports the missing ENV var names so the operator knows
        # exactly what to set. No value is ever read into the view. The live
        # health is merged in afterwards by #index.
        def config_status(spec)
          values = Decidim::Bih::Config.public_send(spec[:config])
          missing = spec[:required].filter_map do |config_key, env_name|
            env_name if values[config_key].blank?
          end

          {
            key: spec[:key],
            configured: missing.empty?,
            missing_env: missing
          }
        end

        # SMTP is configured by the host app's production environment from
        # SMTP_* ENV vars (not by Decidim::Bih::Config). We treat the address as
        # the minimal signal that delivery is wired up; in the test/dev env none
        # is set, so it reports "not configured" without raising.
        def smtp_status
          missing = []
          missing << "SMTP_ADDRESS" if ENV.fetch("SMTP_ADDRESS", nil).blank?

          {
            key: "smtp",
            configured: missing.empty?,
            missing_env: missing
          }
        end

        def city_data_statuses
          provider = Decidim::Bih.city_data_freshness_provider
          return [] unless provider.respond_to?(:statuses)

          Array(provider.statuses(organization: current_organization)).map do |status|
            {
              key: status[:key].to_s,
              label: status[:label].to_s,
              status: status[:status].to_s,
              last_updated_on: status[:last_updated_on].presence,
              refresh_command: status[:refresh_command].to_s,
              detail: status[:detail].to_s
            }
          end
        rescue StandardError => e
          [{
            key: "provider",
            label: I18n.t("decidim.bih.admin.integrations.city_data_title", default: "City data"),
            status: "fail",
            last_updated_on: nil,
            refresh_command: "bin/refresh-city-data.sh",
            detail: sanitize_detail("#{e.class}: #{e.message}")
          }]
        end

        def city_data_previews
          provider = Decidim::Bih.city_data_preview_provider
          return [] unless provider.respond_to?(:previews)

          preview_arguments = {
            organization: current_organization,
            waste_query: params[:city_waste_query],
            parking_query: params[:city_parking_query],
            budget_query: params[:city_budget_query],
            locale: I18n.locale
          }

          Array(provider.previews(**provider_preview_arguments(provider, preview_arguments))).map do |preview|
            sanitize_preview(preview)
          end
        rescue StandardError => e
          [{
            key: "provider",
            label: I18n.t("decidim.bih.admin.integrations.city_data_preview_title", default: "City data preview"),
            query: "",
            query_param: "city_data_query",
            placeholder: "",
            source_url: nil,
            metadata: sanitize_detail("#{e.class}: #{e.message}"),
            rows: []
          }]
        end

        def provider_preview_arguments(provider, arguments)
          parameters = provider.method(:previews).parameters
          return arguments if parameters.any? { |kind, _name| kind == :keyrest }

          accepted_keywords = parameters.filter_map do |kind, name|
            name if [:key, :keyreq].include?(kind)
          end
          arguments.slice(*accepted_keywords)
        rescue NameError
          arguments
        end

        def sanitize_preview(preview)
          normalized = preview.to_h.symbolize_keys
          {
            key: normalized[:key].to_s,
            label: sanitize_detail(normalized[:label]),
            query: sanitize_detail(normalized[:query]),
            query_param: normalized[:query_param].to_s.presence || "city_data_query",
            placeholder: sanitize_detail(normalized[:placeholder]),
            source_url: sanitize_detail(normalized[:source_url]),
            metadata: sanitize_detail(normalized[:metadata]),
            rows: Array(normalized[:rows]).map { |row| sanitize_preview_row(row) }
          }
        end

        def sanitize_preview_row(row)
          normalized = row.to_h.symbolize_keys
          {
            label: sanitize_detail(normalized[:label]),
            value: sanitize_detail(normalized[:value])
          }
        end

        def sanitize_detail(value)
          if defined?(Decidim::Bih::SafeErrorMetadata)
            Decidim::Bih::SafeErrorMetadata.sanitize_text(value, max: 240)
          else
            value.to_s.split.join(" ")[0, 240]
          end
        end
      end
    end
  end
end
