# frozen_string_literal: true

require "json"
require "time"
require "digest"

module Decidim
  module Bih
    # Centralised, boot-validated provider configuration for all external
    # integrations. Reads ENV once on first access (lazily, so tests can stub
    # ENV before requiring). Call Config.reset! between tests / after ENV changes.
    #
    # Usage:
    #   Decidim::Bih::Config.odoo[:base_url]     # => "https://example.org" or nil
    #   Decidim::Bih::Config.infobip[:api_key]   # => "abc123" or nil
    #
    # Boot validation:
    #   Decidim::Bih::Config.validate!            # logs one-line warnings for
    #                                             # partially-configured providers
    module Config
      # Inbound chat channels that can be opened through INFOBIP_CHAT_CHANNELS.
      # viber_bm is Viber Business Messages two-way — the transport MIlica runs
      # on. The separately-billed Viber Bot is NOT here: it has its own
      # endpoint and its own kill switch (viber_bot_enabled?).
      INFOBIP_CHAT_CHANNELS = %w(viber_bm whatsapp messenger instagram).freeze
      WHATSAPP_AUTH_TEMPLATE_LANGUAGE = "sr"

      # Each provider is described as a list of required keys. The provider is
      # considered "not configured" when ALL keys are blank. It is considered
      # "partially configured" (and a warning is logged) when SOME-but-not-all
      # keys are present. Fully-blank = intentionally not set up.
      PROVIDERS = {
        odoo: [:base_url, :db, :login, :api_key],
        infobip: [:base_url, :api_key],
        gemini: [:api_key],
        viber: [:bot_uri]
      }.freeze

      # Upstream AI Studio endpoint. Each operator must explicitly verify the
      # endpoint, credential and data-processing terms for their own provider
      # setup. The report-case access gate separately requires a current receipt
      # for the exact configured global Express request binding.
      GEMINI_AI_STUDIO_BASE_URL = "https://generativelanguage.googleapis.com"

      # Concurrent model-backed chat turns admitted deployment-wide
      # (MILICA_ADMISSION_LIMIT). The cap protects the Puma request pool, not
      # the provider: size it with the pool. The maximum mirrors
      # Concierge::Dialogue::AdmissionControl::MAX_LIMIT, which the constructor
      # enforces independently, so a typo in the environment can never open
      # the pool. Anything unparsable falls back to the shipped default.
      ADMISSION_LIMIT_DEFAULT = 2
      ADMISSION_LIMIT_MAXIMUM = 12

      class << self
        # Odoo JSON-RPC credentials.
        def odoo
          @odoo ||= {
            base_url: ENV.fetch("ODOO_URL", nil),
            db: ENV.fetch("ODOO_DB", nil),
            login: ENV.fetch("ODOO_LOGIN", nil),
            api_key: ENV.fetch("ODOO_API_KEY", nil)
          }.freeze
        end

        # Default country code for MSISDN normalisation. Read from
        # BIH_DEFAULT_COUNTRY_CODE; defaults to "387" (Bosnia and Herzegovina).
        # Used by Decidim::Bih::Infobip::Client#normalize_msisdn when the caller
        # supplies a local-format number (e.g. "06XXXXXXX" → "3876XXXXXXX").
        def default_country_code
          @default_country_code ||= ENV.fetch("BIH_DEFAULT_COUNTRY_CODE", "387")
        end

        # Infobip omnichannel credentials and sender IDs.
        def infobip
          @infobip ||= begin
            viber_business_sender = ENV.fetch("INFOBIP_VIBER_BM_SENDER", nil).presence ||
                                    ENV.fetch("INFOBIP_VIBER_SENDER", nil).presence

            {
              base_url: ENV.fetch("INFOBIP_BASE_URL", nil),
              api_key: ENV.fetch("INFOBIP_API_KEY", nil),
              sms_sender: ENV.fetch("INFOBIP_SMS_SENDER", nil).presence || Decidim::Bih.infobip_sms_sender,
              viber_bm_sender: viber_business_sender,
              viber_bot_sender: ENV.fetch("INFOBIP_VIBER_BOT_SENDER", nil),
              viber_otp_template_id: ENV.fetch("INFOBIP_VIBER_BM_OTP_TEMPLATE_ID", nil),
              viber_login_template_id: ENV.fetch("INFOBIP_VIBER_BM_LOGIN_TEMPLATE_ID", nil),
              viber_template_language: ENV.fetch("INFOBIP_VIBER_BM_TEMPLATE_LANGUAGE", "bs"),
              # Compatibility alias for hosts that still read the former
              # Business Messages-only key. Bot traffic must never use it.
              viber_sender: viber_business_sender,
              whatsapp_sender: ENV.fetch("INFOBIP_WHATSAPP_SENDER", nil),
              whatsapp_template_name: ENV.fetch("INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME", nil),
              # The approved authentication template uses Serbian. Infobip
              # does not accept `bs` for WhatsApp templates.
              whatsapp_template_language: ENV.fetch("INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE", nil).presence || WHATSAPP_AUTH_TEMPLATE_LANGUAGE,
              # Approved UTILITY template for the launch invitation (body {{1}} =
              # reservation number, dynamic URL button = confirm token). Unset
              # until Meta approves it: the invitation then goes Viber -> SMS.
              whatsapp_invitation_template_name: ENV.fetch("INFOBIP_WHATSAPP_INVITATION_TEMPLATE_NAME", nil).presence,
              # What {{1}} of that template is: "entry_code" (the reservation
              # number) or "first_name" (Meta rejects code-like values in a
              # UTILITY template, so the approved variant may carry the name).
              whatsapp_invitation_template_placeholder: ENV.fetch("INFOBIP_WHATSAPP_INVITATION_TEMPLATE_PLACEHOLDER", "entry_code"),
              # Launch campaign messages (P4/P5/P8/P9/P10) may use their
              # WhatsApp templates (Launch::MessageTemplates::WHATSAPP) only
              # once every one of them is APPROVED — one unapproved template
              # makes Infobip reject the whole multi-channel request.
              whatsapp_campaign_templates_enabled: env_flag?("INFOBIP_WHATSAPP_CAMPAIGN_TEMPLATES_ENABLED"),
              # A city-alert template name alone does not prove Meta approval.
              # Operations enables this separate gate only after checking the
              # exact template and language in the provider console.
              whatsapp_city_alert_template_name: ENV.fetch("INFOBIP_WHATSAPP_CITY_ALERT_TEMPLATE_NAME", nil).presence,
              whatsapp_city_alert_template_language: ENV.fetch("INFOBIP_WHATSAPP_CITY_ALERT_TEMPLATE_LANGUAGE", "sr"),
              whatsapp_city_alert_template_approved: env_flag?("INFOBIP_WHATSAPP_CITY_ALERT_TEMPLATE_APPROVED"),
              messenger_sender: ENV.fetch("INFOBIP_MESSENGER_SENDER", nil),
              instagram_sender: ENV.fetch("INFOBIP_INSTAGRAM_SENDER", nil),
              # Explicit launch gate for inbound/reply chat adapters. Sender
              # credentials alone never publish or activate a channel.
              chat_channels: infobip_chat_channels,
              messages_api_enabled: env_flag?("INFOBIP_MESSAGES_API_ENABLED"),
              # LOCAL kill switch for OPTIONAL outbound traffic (account
              # external copies today; campaigns and city alerts as they are
              # routed). It is read on the optional path ONLY — never by the
              # SMS gateway, the phone-message job, the phone sessions
              # controller or the registration resend — so turning it off
              # cannot touch sign-in or phone verification.
              #
              # It does NOT protect the WhatsApp AUTH template from provider
              # enforcement: AUTH and UTILITY/MARKETING templates on one
              # business account share that account's standing, and no
              # application-side split changes that. See
              # host:docs/operations/provider-eligibility.md.
              #
              # Sense is inverted (…_DISABLED, default false) because
              # `env_flag?` takes no default and an absent variable must mean
              # "carry on exactly as today". `optional_traffic_enabled` is
              # therefore true on deploy and nothing changes.
              optional_traffic_enabled: !env_flag?("DECIDIM_BIH_OPTIONAL_TRAFFIC_DISABLED")
            }.freeze
          end
        end

        # Gemini / Vertex AI credentials and model selection.
        def report_case_model = ENV.fetch("REPORT_CASE_MODEL", "gemini-3.8-flash")

        def report_case_check_model = ENV.fetch("REPORT_CASE_CHECK_MODEL", report_case_model)

        # Express mode binds the request to the global endpoint and API key.
        # The project is a configured label: this client cannot prove key ownership.
        def report_case_model_access_binding(api_key: gemini[:api_key], base_url: gemini[:base_url])
          return nil unless base_url == "https://aiplatform.googleapis.com" && api_key.present?
          return nil unless ENV.fetch("GOOGLE_CLOUD_LOCATION", "global") == "global"

          project = ENV.fetch("GOOGLE_CLOUD_PROJECT", nil)
          return nil if project.present? && !project.match?(/\A[a-z][a-z0-9-]+\z/)

          {
            "mode" => "vertex_express",
            "base_url" => base_url,
            "request_location" => "global",
            "configured_project" => project,
            "project_ownership_verified" => false,
            "credential_sha256" => Digest::SHA256.hexdigest("report-case-access-v2\0#{api_key}")
          }
        end

        def report_case_model_access_verified?(model)
          binding = report_case_model_access_binding
          return false unless binding

          path = ENV["REPORT_CASE_MODEL_ACCESS_RECEIPT"].to_s
          return false if path.strip.empty?

          return false unless File.file?(path) && !File.symlink?(path) && File.size(path) <= 16_384

          report_case_model_receipt_matches?(JSON.parse(File.read(path)), binding:, model:)
        rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError, KeyError, ArgumentError, TypeError
          false
        end

        def report_case_model_receipt_matches?(receipt, binding:, model:)
          return false unless receipt["source"] == "runtime-probe-v2" && receipt["request_binding"] == binding
          return false unless Time.iso8601(receipt.fetch("verified_at")) <= Time.current

          Array(receipt["models"]).any? do |entry|
            entry.is_a?(Hash) && entry["model"] == model && entry["answered"] == true &&
              entry["request_path"] == "/v1/publishers/google/models/#{model}:generateContent"
          end
        end

        def report_case_daily_usd = ENV.fetch("REPORT_CASE_DAILY_USD", "5")

        def gemini
          @gemini ||= {
            api_key: ENV.fetch("GEMINI_API_KEY", nil),
            model: ENV.fetch("GEMINI_MODEL", "gemini-flash-lite-latest"),
            base_url: ENV.fetch("GEMINI_BASE_URL", GEMINI_AI_STUDIO_BASE_URL)
          }.freeze
        end

        # Deployment-wide admission limit for slow chat turns, clamped to
        # 1..ADMISSION_LIMIT_MAXIMUM. See ADMISSION_LIMIT_DEFAULT.
        def admission_limit
          @admission_limit ||= begin
            Integer(ENV.fetch("MILICA_ADMISSION_LIMIT", ADMISSION_LIMIT_DEFAULT.to_s), 10).clamp(1, ADMISSION_LIMIT_MAXIMUM)
          rescue ArgumentError, TypeError
            ADMISSION_LIMIT_DEFAULT
          end
        end

        # Viber / Infobip bot configuration.
        def viber
          @viber ||= {
            bot_uri: ENV.fetch("VIBER_BOT_URI", nil),
            # Master kill switch for the separately-billed Viber Bot product.
            # Default false: the deployment runs on Viber Business Messages
            # only, and the Bot must never come back on as a side effect of
            # someone setting a sender id. See viber_bot_enabled?.
            bot_enabled: env_flag?("DECIDIM_BIH_VIBER_BOT_ENABLED"),
            webhook_secret: ENV.fetch("VIBER_WEBHOOK_SECRET", nil),
            image_host_allowlist: ENV.fetch("VIBER_IMAGE_HOST_ALLOWLIST", nil),
            public_onboarding_enabled: ENV.fetch(
              "DECIDIM_BIH_VIBER_PUBLIC_ONBOARDING_ENABLED",
              "false"
            ).match?(/\A(true|1|yes|on)\z/i)
          }.freeze
        end

        # Infobip bills Viber Business Messages and Viber Bot as two separate
        # products. This deployment launched on Business Messages only, so the
        # Bot is OFF unless DECIDIM_BIH_VIBER_BOT_ENABLED is explicitly set.
        #
        # This is deliberately the ONLY way to turn the Bot back on — there is
        # no admin UI for it. Credentials alone must never activate a billed
        # channel, which is why this is checked in addition to (not instead of)
        # Infobip::Client#viber_bot_configured?. The pair is combined in
        # Infobip::Client#viber_bot_active?, which every Bot runtime path uses.
        def viber_bot_enabled?
          viber[:bot_enabled]
        end

        # Public Bot entry points must stay hidden unless the inbound callback
        # can authenticate provider traffic. This mirrors the host webhook's
        # minimum secret length without coupling reusable UI code to a host
        # controller constant.
        def viber_webhook_configured?
          viber[:webhook_secret].to_s.bytesize >= 16
        end

        # Maximum time for each non-final channel in the provider-managed phone
        # delivery chain. The Messages API minimum is 10 seconds. The legacy
        # INFOBIP_VIBER_FAILOVER_MINUTES setting remains a compatibility fallback.
        def phone_channel_validity_seconds
          @phone_channel_validity_seconds ||= begin
            configured = ENV.fetch("INFOBIP_PHONE_CHANNEL_VALIDITY_SECONDS", nil)
            seconds = configured.presence&.to_i || (viber_failover_minutes * 60)
            [seconds, 10].max
          end
        end

        # Authentication WhatsApp is eligible only with a sender, template,
        # and a language accepted by the provider. Treat the known-invalid
        # Bosnian language as not ready so the caller safely falls through to
        # SMS instead of sending a rejected request.
        def whatsapp_phone_auth_configured?
          config = infobip
          config[:whatsapp_sender].present? &&
            config[:whatsapp_template_name].present? &&
            config[:whatsapp_template_language].present? &&
            config[:whatsapp_template_language].to_s == WHATSAPP_AUTH_TEMPLATE_LANGUAGE
        end

        # Backwards-compatible legacy Viber-to-SMS failover setting.
        def viber_failover_minutes
          @viber_failover_minutes ||= ENV.fetch("INFOBIP_VIBER_FAILOVER_MINUTES", 1).to_i
        end

        # Clears all memoized config — call in tests after ENV manipulation.
        def reset!
          @odoo = @infobip = @gemini = @viber = @default_country_code = nil
          @viber_failover_minutes = @phone_channel_validity_seconds = @admission_limit = nil
        end

        # Logs a one-line warning per provider that is partially configured
        # (some-but-not-all required keys present). Never raises — a missing
        # provider is not an error; only an ambiguous partial config is suspicious.
        def validate!
          PROVIDERS.each do |provider, required_keys|
            values = public_send(provider).slice(*required_keys).values
            present_count = values.count(&:present?)
            next if present_count.zero? || present_count == required_keys.size

            missing = required_keys.zip(values).reject { |_, v| v.present? }.map(&:first)
            Rails.logger.warn(
              "[Decidim::Bih::Config] #{provider} is partially configured " \
              "(#{present_count}/#{required_keys.size} keys set; " \
              "missing: #{missing.join(", ")})"
            )
          end

          warn_gemini_base_url!
          warn_infobip_phone_delivery!
        end

        # True when Gemini is "configured but misrouted": an api_key IS present
        # but base_url is still the blocked AI Studio host (GEMINI_AI_STUDIO_BASE_URL),
        # which silently 401s for this deployment's Vertex-only GCP project. This
        # is the single source of truth shared by the boot-time warning
        # (warn_gemini_base_url!) and the admin integrations-health page's
        # degraded-state banner — so the two can never disagree.
        def gemini_misrouted?
          gemini[:api_key].present? && gemini[:base_url] == GEMINI_AI_STUDIO_BASE_URL
        end

        private

        def env_flag?(key)
          ENV.fetch(key, "false").match?(/\A(true|1|yes|on)\z/i)
        end

        def infobip_chat_channels
          ENV.fetch("INFOBIP_CHAT_CHANNELS", "")
             .split(",")
             .map { |channel| channel.strip.downcase }
             .select { |channel| INFOBIP_CHAT_CHANNELS.include?(channel) }
             .uniq
             .freeze
        end

        def warn_infobip_phone_delivery!
          config = infobip
          return unless config[:messages_api_enabled]

          if config[:sms_sender].blank?
            Rails.logger.warn(
              "[Decidim::Bih::Config] Infobip Messages API phone delivery is enabled " \
              "but INFOBIP_SMS_SENDER is missing; SMS must be the final channel"
            )
          end

          if config[:whatsapp_sender].present? && config[:whatsapp_template_name].blank?
            Rails.logger.warn(
              "[Decidim::Bih::Config] INFOBIP_WHATSAPP_SENDER is set but " \
              "INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME is missing; WhatsApp will be skipped " \
              "for phone verification and sign-in delivery"
            )
          end

          return unless config[:whatsapp_sender].present? && config[:whatsapp_template_name].present?
          return if config[:whatsapp_template_language].to_s == WHATSAPP_AUTH_TEMPLATE_LANGUAGE

          Rails.logger.warn(
            "[Decidim::Bih::Config] INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE=#{config[:whatsapp_template_language]} " \
            "does not match the approved WhatsApp AUTH language #{WHATSAPP_AUTH_TEMPLATE_LANGUAGE}; " \
            "WhatsApp will be skipped"
          )
        end

        # A Gemini key with the host left at the AI Studio default is the
        # silent-401 trap: that host is blocked for this deployment's GCP
        # project, so generation fails at runtime instead of at boot. Make it
        # loud. (No warning when no key is set — the provider is then simply off.)
        def warn_gemini_base_url!
          return unless gemini_misrouted?

          Rails.logger.warn(
            "[Decidim::Bih::Config] gemini api_key is set but GEMINI_BASE_URL is " \
            "still the AI Studio default (#{GEMINI_AI_STUDIO_BASE_URL}). That host " \
            "is blocked for the production GCP project; set GEMINI_BASE_URL to the " \
            "Vertex host (https://aiplatform.googleapis.com) — see DEPLOYMENT.md 5c."
          )
        end
      end
    end
  end
end
