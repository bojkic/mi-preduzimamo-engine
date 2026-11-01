# frozen_string_literal: true

require "faraday"
require "uri"

module Decidim
  module Bih
    module Infobip
      # Thin HTTP client for the Infobip omnichannel API (https://www.infobip.com).
      # (Decidim::Bih::Infobip::Error is defined in error.rb.)
      #
      # Shared infrastructure for the Bosnian market: used by ordered phone
      # authentication delivery and the Viber civic-concierge bot. Business
      # Messages and Bots are deliberately separate transports: the former is
      # addressed by MSISDN, while the latter is addressed by an opaque Viber
      # bot user ID captured from an inbound interaction.
      # credentials through Decidim::Bih::Config.infobip so all Infobip config
      # is centralised and Config.validate! covers this client's requirements.
      # When unconfigured, callers fall back to a dev/log path rather than erroring.
      #
      # ENV vars consumed (via Config.infobip):
      #   INFOBIP_BASE_URL    e.g. "https://xxxxx.api.infobip.com" (per-account host)
      #   INFOBIP_API_KEY     API key from the Infobip portal
      #   INFOBIP_SMS_SENDER       alphanumeric sender id, e.g. "HostName"
      #   INFOBIP_VIBER_BM_SENDER  Viber Business Messages sender id
      #   INFOBIP_VIBER_BOT_SENDER Viber Bot sender id
      #   INFOBIP_VIBER_SENDER     legacy alias for INFOBIP_VIBER_BM_SENDER
      #   INFOBIP_WHATSAPP_SENDER  WhatsApp sender
      #   INFOBIP_MESSENGER_SENDER Messenger page sender
      #   INFOBIP_INSTAGRAM_SENDER Instagram business-account sender
      #   INFOBIP_CHAT_CHANNELS     explicit comma-separated inbound chat gate
      #
      # TODO: the remaining provider clients (Odoo, Gemini) and ProviderClient
      # base-class adoption are deferred to a later consolidation pass.
      class Client
        DEFAULT_TIMEOUT = 10
        DEFAULT_PHONE_MESSAGE_TTL = 10.minutes

        # How long a NON-auth message may wait on a free channel before the
        # chain moves on. A campaign message or an invitation lives 24 hours,
        # so there is no reason to fall through to a paid SMS because the
        # handset was offline for the 60 seconds an auth code can afford
        # (review 2026-09-07, lane 1 H1 / lane 8 H-3).
        CAMPAIGN_CHANNEL_VALIDITY = 6.hours
        MESSAGES_API_PATH = "/messages-api/1/messages"
        MESSENGER_PHONE_REQUEST_PATH = "/messenger/1/messages"
        MESSENGER_NATIVE_FALLBACK_STATUSES = [400, 401, 403, 404, 422].freeze
        PHONE_CHANNEL_ORDER = [:viber, :whatsapp, :sms].freeze
        PHONE_CHANNEL_CODES = {
          viber: "VIBER_BM",
          whatsapp: "WHATSAPP",
          messenger: "MESSENGER",
          sms: "SMS"
        }.freeze
        CHAT_CHANNEL_CODES = {
          viber_bm: "VIBER_BM",
          whatsapp: "WHATSAPP",
          messenger: "MESSENGER",
          instagram: "INSTAGRAM_DM"
        }.freeze
        CHAT_CHANNEL_SENDERS = {
          viber_bm: :viber_bm_sender,
          whatsapp: :whatsapp_sender,
          messenger: :messenger_sender,
          instagram: :instagram_sender
        }.freeze
        CHAT_CHANNEL_ENV_KEYS = {
          viber_bm: "INFOBIP_VIBER_BM_SENDER",
          whatsapp: "INFOBIP_WHATSAPP_SENDER",
          messenger: "INFOBIP_MESSENGER_SENDER",
          instagram: "INFOBIP_INSTAGRAM_SENDER"
        }.freeze
        # Viber Business Messages is addressed by MSISDN; every other chat
        # channel is addressed by an opaque provider id that must be sent
        # through untouched. See #chat_destination.
        MSISDN_CHAT_CHANNELS = [:viber_bm].freeze
        PROVIDER_ERROR_CODE_PATHS = [
          %w(requestError serviceException messageId),
          %w(requestError policyException messageId),
          %w(requestError validationException messageId),
          %w(status name),
          %w(status id)
        ].freeze
        PROVIDER_ERROR_GROUP_PATHS = [
          %w(status groupName),
          %w(status groupId)
        ].freeze

        attr_reader :base_url, :api_key

        def initialize(base_url: Decidim::Bih::Config.infobip[:base_url],
                       api_key: Decidim::Bih::Config.infobip[:api_key],
                       timeout: DEFAULT_TIMEOUT)
          @base_url = base_url
          @api_key = api_key
          @timeout = timeout
        end

        # True only when both a host and an API key are present. Callers use this
        # to decide between a real send and a dev/log fallback.
        def configured?
          base_url.present? && api_key.present?
        end

        def viber_business_configured?
          configured? && Decidim::Bih::Config.infobip[:viber_bm_sender].present?
        end

        # Credentials-only check: "could this deployment address the Bot?".
        # It deliberately ignores the launch switch so readiness tooling can
        # tell "no Bot credentials" apart from "Bot switched off".
        # Runtime senders must use #viber_bot_active? instead.
        def viber_bot_configured?
          configured? && Decidim::Bih::Config.infobip[:viber_bot_sender].present?
        end

        # The gate every Bot runtime path checks: credentials present AND the
        # separately-billed Bot product explicitly switched on. Business
        # Messages is unaffected by this — see #viber_business_configured?.
        def viber_bot_active?
          Decidim::Bih::Config.viber_bot_enabled? && viber_bot_configured?
        end

        # True only when credentials, the channel sender and the explicit
        # INFOBIP_CHAT_CHANNELS launch gate are all present. Viber Bot remains
        # independently controlled by #viber_bot_configured? for compatibility.
        def chat_channel_configured?(channel)
          normalized = normalize_chat_channel(channel)
          return false unless normalized

          config = Decidim::Bih::Config.infobip
          configured? && config[:chat_channels].include?(normalized.to_s) &&
            config[CHAT_CHANNEL_SENDERS.fetch(normalized)].present?
        end

        # Sends a single SMS. Returns the parsed response hash on success.
        # Raises Decidim::Bih::Infobip::Error on transport or API failure.
        def send_sms(to:, text:, from: Decidim::Bih::Config.infobip[:sms_sender])
          post(
            "/sms/2/text/advanced",
            messages: [{ from: from, destinations: [{ to: normalize_msisdn(to) }], text: text }]
          )
        end

        # Sends one time-sensitive phone message using the shared delivery
        # policy: Viber Business Messages, WhatsApp AUTH, then SMS. When Infobip's
        # Messages API is enabled, Infobip owns delivery-status-aware channel
        # switching after accepting this single request. Messenger is
        # deliberately excluded: phone authentication must not depend on an
        # unrelated linked chat session.
        #
        # Until Messages API and the additional senders are enabled, the same
        # call safely degrades to Viber with native SMS failover, or plain SMS.
        # If Infobip rejects the multi-channel request before accepting it, a
        # final direct SMS request is attempted so authentication is not blocked
        # by a Messages API/template configuration error.
        #
        # +channels+ (optional array of symbols, e.g. [:sms]): when given and
        # non-empty, restricts delivery to exactly this ordered subset of
        # PHONE_CHANNEL_ORDER — nil or [] mean "no restriction" (Decidim's
        # MobilePhoneForm defaults its delivery_channels attribute to []).
        # A non-empty subset is validated strictly (no duplicates, no unknown
        # names, PHONE_CHANNEL_ORDER order), and SMS must still end up last
        # after filtering, or the same INFOBIP_SMS_SENDER-required error is
        # raised. Callers use this to force SMS-only delivery regardless of
        # which richer channels are otherwise configured.
        # +messenger+ is accepted and ignored. Messenger is not a phone-auth
        # channel (see above), so nothing here reads it; the keyword stays
        # because envelopes already sitting in the queue carry it, and a
        # retried job must not die on an unknown keyword.
        #
        # +whatsapp_template+ (optional Hash) puts WhatsApp into the chain for
        # a message that is NOT a verification code. WhatsApp lets a business
        # open a conversation only with a Meta-approved template, so free text
        # never goes there: the caller names the approved template and fills
        # its placeholders. Shape:
        #   { name: "mi_pozivnica_lansiranje_v1", language: "sr",
        #     body: { "1" => "MI-ABCDE-FGHIJ" },      # numbered placeholders
        #     button_suffix: "<token>" }              # dynamic-URL button, optional
        # Without it (and without +otp_code+) WhatsApp is skipped, exactly as
        # before. +otp_code+ wins when both are given: a code always travels
        # through the AUTH template.
        #
        # +final_sms+ (default true): every authentication message must end
        # in SMS — the one channel every phone has. A campaign message that
        # has no SMS text (P4/P5/P8/P9/P10 are Viber/WhatsApp-only by the
        # client's channel rules) passes +final_sms: false+: the chain is then
        # Viber -> WhatsApp with no SMS leg, and when neither is configured
        # the call raises Error instead of pushing rich text into an SMS.
        def send_phone_message(to:, text:, viber_text: nil, viber_template: nil, expires_at: nil, messenger: nil, # rubocop:disable Lint/UnusedMethodArgument, Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
                               channels: nil, otp_code: nil, whatsapp_template: nil, final_sms: true,
                               channel_validity_seconds: nil)
          requested_channels = normalize_phone_channel_subset(channels)
          channels = phone_delivery_channels(to:, otp_code:, whatsapp_template:)
          channels = channels.select { |channel| requested_channels.include?(channel[:name]) } if requested_channels
          channels = channels.reject { |channel| channel[:name] == :sms } unless final_sms
          raise Error, "Infobip phone delivery requires INFOBIP_SMS_SENDER" if final_sms && channels.last&.fetch(:name) != :sms
          raise Error, "Infobip phone delivery has no configured channel for this message" if channels.empty?

          channels = fit_phone_channels_to_expiry(channels, expires_at:)

          if messages_api_enabled? && (channels.size > 1 || !final_sms)
            begin
              return send_messages_api_phone_message(
                channels:,
                text:,
                viber_text:,
                viber_template:,
                expires_at:,
                otp_code:,
                whatsapp_template:,
                channel_validity_seconds:
              )
            rescue Error => e
              raise unless final_sms && e.definitive_rejection?

              log_phone_fallback(to:, strategy: "Messages API", error: e)
              return send_sms(to:, text:)
            end
          end

          return send_sms(to:, text:) unless channels.any? { |channel| channel[:name] == :viber }

          begin
            send_legacy_viber_phone_message(to:, text:, viber_text:, viber_template:, expires_at:, final_sms:)
          rescue Error => e
            raise unless final_sms && e.definitive_rejection?

            log_phone_fallback(to:, strategy: "Viber", error: e)
            send_sms(to:, text:)
          end
        end

        # Sends a single Viber text message via Infobip's Viber Business
        # Messages API. Returns the parsed response hash on success; raises
        # Decidim::Bih::Infobip::Error on transport or API failure.
        #
        # Infobip's Viber Business Messages contract uses POST
        # "/viber/2/messages" with the body shape
        #   { messages: [{ sender:, destinations: [{ to: }], content: { type: "TEXT", text: } }] }
        # +sms_failover+ (optional Hash): when present, instructs Infobip to
        # automatically send an SMS if the Viber message is not delivered within
        # the specified validity period. Infobip processes this natively — no
        # second API call is needed. Expected shape (all keys optional):
        #   {
        #     sender:          SMS sender id (defaults to Config.infobip[:sms_sender]),
        #     text:            SMS text (required when sms_failover is given),
        #     validity_period: { amount: <integer>, timeUnit: "MINUTES" }
        #                      (defaults to { amount: 1, timeUnit: "MINUTES" })
        #   }
        # Infobip nests the smsFailover object inside message options. Shape:
        #   smsFailover: { sender:, text:, validityPeriod: { amount:, timeUnit: } }
        def send_viber_business(to:, text:, sender: Decidim::Bih::Config.infobip[:viber_bm_sender],
                                validity_period: nil, sms_failover: nil)
          message = {
            sender: sender,
            destinations: [{ to: normalize_msisdn(to) }],
            content: { type: "TEXT", text: text }
          }

          options = {}
          options[:validityPeriod] = validity_period if validity_period.present?

          if sms_failover.is_a?(Hash)
            options[:smsFailover] = {
              sender: sms_failover[:sender].presence || Decidim::Bih::Config.infobip[:sms_sender],
              text: sms_failover[:text],
              validityPeriod: sms_failover[:validity_period] || { amount: 1, timeUnit: "MINUTES" }
            }
          end
          message[:options] = options if options.any?

          post("/viber/2/messages", messages: [message])
        end

        # Sends an approved Viber Business Messages template. OTP templates use
        # the parameter key +pin+; link templates should keep the approved host
        # literal and accept only the dynamic +token+ path segment.
        def send_viber_business_template(to:, template_id:, parameters:, language:, sender: Decidim::Bih::Config.infobip[:viber_bm_sender], # rubocop:disable Metrics/ParameterLists
                                         validity_period: nil, sms_failover: nil)
          message = {
            sender:,
            destinations: [{ to: normalize_msisdn(to) }],
            content: {
              type: "TEMPLATE",
              templateId: template_id,
              language:,
              parameters: parameters.to_h.stringify_keys
            }
          }
          options = viber_business_options(validity_period:, sms_failover:)
          message[:options] = options if options.any?

          post("/viber/2/messages", messages: [message])
        end

        # Backwards-compatible name for callers that send a phone-addressed
        # Viber Business Message. Bot replies must call #send_viber_bot.
        def send_viber(**)
          send_viber_business(**)
        end

        # Legacy Viber Business IMAGE transport retained for compatibility.
        # Concierge stickers use #send_viber_bot_image instead. This method uses
        # the same Viber Business Messages API as #send_viber. It returns the parsed response hash on
        # success; raises Decidim::Bih::Infobip::Error on transport or API
        # failure. +text+ is an optional caption sent alongside the image.
        #
        # ASSUMPTION (verify against Infobip "Send Viber message" docs, same
        # caveat as #send_viber): the IMAGE content shape is
        #   content: { type: "IMAGE", imageUrl:, text: (optional caption) }
        # where +imageUrl+ must be a publicly reachable https URL. If your
        # account is on a different Viber API version, only this body literal
        # (and the path) need editing — exactly as for #send_viber.
        def send_viber_image(to:, image_url:, text: nil, sender: Decidim::Bih::Config.infobip[:viber_bm_sender])
          content = { type: "IMAGE", imageUrl: image_url }
          content[:text] = text if text.present?

          post(
            "/viber/2/messages",
            messages: [
              {
                sender: sender,
                destinations: [{ to: normalize_msisdn(to) }],
                content: content
              }
            ]
          )
        end

        # Sends a text reply to a Viber Bot user through Infobip Messages API.
        # +to+ is an opaque channel-specific bot user ID and is intentionally
        # never passed through MSISDN normalization.
        def send_viber_bot(to:, text:, sender: Decidim::Bih::Config.infobip[:viber_bot_sender])
          send_viber_bot_content(
            to:,
            sender:,
            body: { type: "TEXT", text: text }
          )
        end

        # Sends an image to an opaque Viber Bot user ID. Messages API uses the
        # common IMAGE body shape and accepts an optional caption in +text+.
        def send_viber_bot_image(to:, image_url:, text: nil,
                                 sender: Decidim::Bih::Config.infobip[:viber_bot_sender])
          body = { type: "IMAGE", url: image_url }
          body[:text] = text if text.present?
          send_viber_bot_content(to:, sender:, body:)
        end

        # Sends one free-form text reply within a user-initiated channel
        # session. The caller owns session timing; SendChatTextJob adds a
        # conservative expiry so retries cannot extend that window indefinitely.
        # +to+ is an opaque channel identifier (including WhatsApp
        # contact.userId/BSUID) for every channel except Viber Business
        # Messages, which is MSISDN-addressed — see #chat_destination.
        # +request_phone+ selects Messenger's native PHONE_NUMBER quick reply;
        # other text continues through the unified Messages API.
        def send_chat_text(channel:, to:, text:, sender: nil, request_phone: false)
          normalized = normalize_chat_channel(channel)
          raise Error, "Unsupported Infobip chat channel" unless normalized

          sender = enabled_chat_sender!(normalized, sender)
          validate_chat_content!(to, text)
          validate_phone_request!(normalized, request_phone)

          if request_phone
            send_messenger_phone_request(to:, text:, sender:)
          else
            send_unified_chat_text(channel: normalized, to:, text:, sender:)
          end
        rescue Error => e
          channel_name = normalized && normalized.to_s
          safe_error = Error.new(
            "Infobip #{channel_name || "chat"} chat delivery failed",
            **e.metadata
          )
          raise safe_error, cause: nil
        end

        # Sends a provider-safe static image in the same citizen-initiated
        # session as a chat reply. The common Messages API IMAGE body is
        # natively supported by WhatsApp, Messenger and Instagram DM. Persona
        # animations are resolved to static HTTPS assets before this boundary;
        # the client never accepts a local path or an unbounded caption.
        def send_chat_image(channel:, to:, image_url:, text: nil, sender: nil)
          normalized = normalize_chat_channel(channel)
          raise Error, "Unsupported Infobip chat channel" unless normalized

          sender = enabled_chat_sender!(normalized, sender)
          validate_chat_image_content!(to, image_url, text)

          body = { type: "IMAGE", url: image_url.to_s }
          body[:text] = text.to_s if text.present?
          post(
            MESSAGES_API_PATH,
            messages: [
              {
                channel: CHAT_CHANNEL_CODES.fetch(normalized),
                sender:,
                destinations: [{ to: chat_destination(normalized, to) }],
                content: { body: },
                options: { adaptationMode: false }
              }
            ]
          )
        rescue Error => e
          channel_name = normalized && normalized.to_s
          raise Error.new(
            "Infobip #{channel_name || "chat"} chat media delivery failed",
            **e.metadata
          ), cause: nil
        end

        # POSTs a JSON body to an Infobip endpoint with the documented
        # `Authorization: App <key>` scheme.
        def post(path, body)
          Decidim::Bih::Instrumentation.instrument(
            "infobip.request",
            provider: "infobip",
            channel: infobip_channel(path),
            path: path,
            configured: configured?
          ) do |event|
            raise Error, "Infobip client is not configured (set INFOBIP_BASE_URL and INFOBIP_API_KEY)" unless configured?

            response = connection.post(path) do |req|
              req.headers["Authorization"] = "App #{api_key}"
              req.headers["Content-Type"] = "application/json"
              req.headers["Accept"] = "application/json"
              req.body = body.to_json
            end
            event[:http_status] = response.status
            handle(response)
          end
        rescue Faraday::Error => e
          raise Error, "Infobip transport error: #{Decidim::Bih::LogRedactor.error_message(e)}"
        end

        # Messages API delivery reports are returned once. Always constrain the
        # request to one previously accepted message ID; never consume a tenant's
        # unrelated reports. This endpoint also includes native channel sends.
        def message_delivery_reports(message_id:)
          raise ArgumentError, "message ID required" if message_id.blank?
          raise Error, "Infobip client is not configured" unless configured?

          response = connection.get("/messages-api/1/reports", { messageId: message_id.to_s, limit: 100 }) do |request|
            request.headers["Authorization"] = "App #{api_key}"
            request.headers["Accept"] = "application/json"
          end
          handle(response)
        rescue Faraday::Error
          raise Error, "Infobip delivery report transport error"
        end

        private

        # nil AND [] both mean "no restriction". Decidim's MobilePhoneForm
        # declares `attribute :delivery_channels, [String]`, whose default is
        # [] rather than nil, so every stock registration SMS arrives here with
        # an empty array; treating that as an empty subset would raise on the
        # most common send there is.
        def normalize_phone_channel_subset(channels)
          return if channels.blank?

          requested = Array(channels).map { |channel| channel.to_s.strip.downcase.to_sym }
          raise Error, "Infobip phone delivery channel subset contains duplicates" if requested.uniq.size != requested.size

          unknown = requested - PHONE_CHANNEL_ORDER
          raise Error, "Infobip phone delivery channel subset is invalid" if unknown.any?

          expected_order = PHONE_CHANNEL_ORDER.select { |channel| requested.include?(channel) }
          raise Error, "Infobip phone delivery channel subset is out of order" unless requested == expected_order

          requested
        rescue NoMethodError, TypeError
          raise Error, "Infobip phone delivery channel subset is invalid"
        end

        def messages_api_enabled?
          Decidim::Bih::Config.infobip[:messages_api_enabled]
        end

        def normalize_chat_channel(channel)
          normalized = channel.to_s.strip.downcase.to_sym
          normalized if CHAT_CHANNEL_CODES.has_key?(normalized)
        end

        def enabled_chat_sender!(channel, sender)
          config = Decidim::Bih::Config.infobip
          enabled = config[:chat_channels].include?(channel.to_s)
          raise Error, "Infobip chat channel is not enabled in INFOBIP_CHAT_CHANNELS" unless enabled

          sender = sender.presence || config[CHAT_CHANNEL_SENDERS.fetch(channel)]
          raise Error, "Infobip chat delivery requires #{CHAT_CHANNEL_ENV_KEYS.fetch(channel)}" if sender.blank?

          sender
        end

        # Viber Business Messages destinations are phone numbers and get the
        # same normalization every other MSISDN-addressed send uses. Opaque
        # chat identifiers (WhatsApp BSUID, Messenger PSID, Instagram IGSID)
        # must never be run through it — digits would be stripped out of a
        # valid id and the reply would go nowhere.
        def chat_destination(channel, to)
          return normalize_msisdn(to) if MSISDN_CHAT_CHANNELS.include?(channel)

          to.to_s
        end

        def validate_chat_content!(to, text)
          raise Error, "Infobip chat delivery requires a recipient" if to.blank?
          raise Error, "Infobip chat delivery requires text" if text.blank?
        end

        def validate_chat_image_content!(to, image_url, text)
          raise Error, "Infobip chat delivery requires a recipient" if to.blank?

          uri = URI.parse(image_url.to_s)
          raise Error, "Infobip chat media URL is invalid" unless
            uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? && image_url.to_s.bytesize <= 2048
          raise Error, "Infobip chat media caption is too long" if text.to_s.bytesize > 1024
        rescue URI::InvalidURIError
          raise Error, "Infobip chat media URL is invalid"
        end

        def phone_delivery_channels(to:, otp_code:, whatsapp_template: nil)
          config = Decidim::Bih::Config.infobip
          msisdn = normalize_msisdn(to)

          PHONE_CHANNEL_ORDER.filter_map do |name|
            sender = phone_channel_sender(name, config)
            destination = msisdn
            next if sender.blank? || destination.blank?
            next if name == :whatsapp && !whatsapp_eligible?(otp_code:, whatsapp_template:)

            { name:, code: PHONE_CHANNEL_CODES.fetch(name), sender:, to: destination }
          end
        end

        # WhatsApp carries either a verification code (AUTH template, host
        # config) or a caller-named approved template — never free text.
        def whatsapp_eligible?(otp_code:, whatsapp_template:)
          return Decidim::Bih::Config.whatsapp_phone_auth_configured? if otp_code.present?

          whatsapp_template.present? && template_value(whatsapp_template, :name).present?
        end

        def phone_channel_sender(name, config)
          {
            viber: config[:viber_bm_sender],
            whatsapp: config[:whatsapp_sender],
            sms: config[:sms_sender]
          }.fetch(name)
        end

        # Infobip requires at least ten seconds per failover step. If a queued
        # token is too close to expiry for every configured channel, preserve
        # the earliest eligible channels and mandatory final SMS rather than
        # letting the SMS window begin after the token has expired.
        def fit_phone_channels_to_expiry(channels, expires_at:)
          available_slots = [phone_message_remaining_seconds(expires_at) / 10, 1].max
          return channels if channels.size <= available_slots
          return [channels.last] if available_slots == 1

          channels.first(available_slots - 1) + [channels.last]
        end

        def send_messages_api_phone_message(channels:, text:, viber_text:, viber_template:, expires_at:, otp_code:, whatsapp_template: nil, channel_validity_seconds: nil) # rubocop:disable Metrics/ParameterLists
          validity_periods = phone_validity_periods(channels.size, expires_at:, channel_validity_seconds:)
          primary = phone_channel_payload(channels.first, text:, viber_text:, viber_template:, otp_code:, whatsapp_template:)
          primary[:destinations] = [
            {
              byChannel: channels.map { |channel| { channel: channel[:code], to: channel[:to] } }
            }
          ]
          primary[:options] = {
            validityPeriod: validity_period(validity_periods.first),
            adaptationMode: false
          }
          failover = channels.drop(1).each_with_index.map do |channel, index|
            phone_channel_payload(channel, text:, viber_text:, viber_template:, otp_code:, whatsapp_template:).merge(
              validityPeriod: validity_period(validity_periods.fetch(index + 1))
            )
          end
          primary[:failover] = failover if failover.any?

          post(MESSAGES_API_PATH, messages: [primary])
        end

        def phone_channel_payload(channel, text:, viber_text:, viber_template:, otp_code:, whatsapp_template: nil) # rubocop:disable Metrics/ParameterLists
          payload = {
            channel: channel[:code],
            sender: channel[:sender]
          }

          if channel[:name] == :viber && viber_template.present?
            payload[:template] = {
              templateName: template_value(viber_template, :template_id),
              language: template_value(viber_template, :language)
            }
            parameters = template_value(viber_template, :parameters).to_h.stringify_keys
            payload[:content] = { body: parameters.merge("type" => "TEXT") }
          elsif channel[:name] == :whatsapp && otp_code.blank?
            payload.merge!(whatsapp_template_payload(whatsapp_template))
          elsif channel[:name] == :whatsapp
            config = Decidim::Bih::Config.infobip
            payload[:template] = {
              templateName: config[:whatsapp_template_name],
              language: config[:whatsapp_template_language]
            }
            # AUTH templates receive only the separate OTP. Their dynamic
            # copy-code button uses the same code as its suffix; the magic
            # URL and full SMS text must never enter this WhatsApp payload.
            code = otp_code.to_s
            payload[:content] = {
              body: { "1" => code, "type" => "TEXT" },
              buttons: [{ suffix: code, type: "OPEN_URL" }]
            }
          else
            channel_text = channel[:name] == :viber ? (viber_text.presence || text) : text
            payload[:content] = { body: { text: channel_text, type: "TEXT" } }
          end

          payload
        end

        # A caller-named approved template (see #send_phone_message). Only
        # its placeholders and the button suffix travel; the SMS text and any
        # link inside it stay out of the WhatsApp payload.
        def whatsapp_template_payload(whatsapp_template)
          body = template_value(whatsapp_template, :body).to_h.transform_keys(&:to_s).transform_values(&:to_s)
          content = { body: body.merge("type" => "TEXT") }
          suffix = template_value(whatsapp_template, :button_suffix)
          content[:buttons] = [{ suffix: suffix.to_s, type: "OPEN_URL" }] if suffix.present?

          {
            template: {
              templateName: template_value(whatsapp_template, :name),
              language: template_value(whatsapp_template, :language).presence || Decidim::Bih::Config.infobip[:whatsapp_template_language]
            },
            content:
          }
        end

        def send_legacy_viber_phone_message(to:, text:, viber_text:, viber_template:, expires_at:, final_sms: true) # rubocop:disable Metrics/ParameterLists
          primary_seconds, sms_seconds = phone_validity_periods(2, expires_at:)
          options = { validity_period: validity_period(primary_seconds) }
          if final_sms
            options[:sms_failover] = {
              sender: Decidim::Bih::Config.infobip[:sms_sender],
              text:,
              validity_period: validity_period(sms_seconds)
            }
          end

          if viber_template.present?
            send_viber_business_template(
              to:,
              template_id: template_value(viber_template, :template_id),
              parameters: template_value(viber_template, :parameters),
              language: template_value(viber_template, :language),
              **options
            )
          else
            send_viber_business(to:, text: viber_text.presence || text, **options)
          end
        end

        def phone_validity_periods(channel_count, expires_at:, channel_validity_seconds: nil)
          remaining = phone_message_remaining_seconds(expires_at)
          requested = channel_validity_seconds.to_i.positive? ? channel_validity_seconds.to_i : Decidim::Bih::Config.phone_channel_validity_seconds
          early_channel_seconds = requested.clamp(
            10,
            [remaining / channel_count, 10].max
          )
          periods = Array.new(channel_count, early_channel_seconds)
          periods[-1] = [remaining - (early_channel_seconds * (channel_count - 1)), 10].max
          periods
        end

        def phone_message_remaining_seconds(expires_at)
          expiry = expires_at.present? ? expires_at.to_time : DEFAULT_PHONE_MESSAGE_TTL.from_now
          (expiry - Time.current).floor.clamp(10, 48.hours.to_i)
        end

        def validity_period(seconds)
          { amount: seconds, timeUnit: "SECONDS" }
        end

        def log_phone_fallback(to:, strategy:, error:)
          Rails.logger.warn(
            "[Infobip::Client] #{strategy} phone delivery was rejected for " \
            "#{Decidim::Bih::LogRedactor.mask_identifier(to)}: " \
            "#{Decidim::Bih::LogRedactor.error_message(error)}; attempting direct SMS"
          )
        end

        def template_value(template, key)
          template[key] || template[key.to_s]
        end

        def viber_business_options(validity_period:, sms_failover:)
          options = {}
          options[:validityPeriod] = validity_period if validity_period.present?
          if sms_failover.is_a?(Hash)
            options[:smsFailover] = {
              sender: sms_failover[:sender].presence || Decidim::Bih::Config.infobip[:sms_sender],
              text: sms_failover[:text],
              validityPeriod: sms_failover[:validity_period] || { amount: 1, timeUnit: "MINUTES" }
            }
          end
          options
        end

        def send_viber_bot_content(to:, sender:, body:)
          raise Error, "Viber Bot delivery requires INFOBIP_VIBER_BOT_SENDER" if sender.blank?

          post(
            MESSAGES_API_PATH,
            messages: [
              {
                channel: "VIBER_BOT",
                sender: sender,
                destinations: [{ to: to.to_s }],
                content: { body: body },
                options: { adaptationMode: false }
              }
            ]
          )
        end

        def validate_phone_request!(channel, request_phone)
          raise Error, "Infobip chat phone request must be boolean" unless [true, false].include?(request_phone)
          return unless request_phone && channel != :messenger

          raise Error, "Infobip chat phone request requires Messenger"
        end

        def send_messenger_phone_request(to:, text:, sender:)
          post(
            MESSENGER_PHONE_REQUEST_PATH,
            messages: [
              {
                sender:,
                destinations: [{ to: to.to_s }],
                content: { type: "TEXT", text: text.to_s },
                quickReplies: [{ type: "PHONE_NUMBER" }]
              }
            ]
          )
        rescue Error => e
          raise unless MESSENGER_NATIVE_FALLBACK_STATUSES.include?(e.http_status.to_i)

          send_unified_chat_text(channel: :messenger, to:, text:, sender:)
        end

        def send_unified_chat_text(channel:, to:, text:, sender:)
          post(
            MESSAGES_API_PATH,
            messages: [
              {
                channel: CHAT_CHANNEL_CODES.fetch(channel),
                sender:,
                destinations: [{ to: chat_destination(channel, to) }],
                content: { body: { type: "TEXT", text: text.to_s } },
                options: { adaptationMode: false }
              }
            ]
          )
        end

        def handle(response)
          return parse(response.body) if response.success?

          raise Error.new(
            "Infobip API error (HTTP #{response.status}): #{Decidim::Bih::LogRedactor.provider_response(response.body)}",
            http_status: response.status,
            **provider_error_metadata(response.body)
          )
        end

        def provider_error_metadata(body)
          payload = parse(body)
          {
            error_code: provider_error_value(payload, PROVIDER_ERROR_CODE_PATHS),
            error_group: provider_error_value(payload, PROVIDER_ERROR_GROUP_PATHS)
          }
        end

        def provider_error_value(payload, paths)
          paths.each do |path|
            value = path.reduce(payload) { |node, key| provider_field(node, key) }
            return value if value.present?
          end

          nil
        end

        def provider_field(node, key)
          return unless node.respond_to?(:key?)
          return node[key] if node.has_key?(key)

          symbol_key = key.to_sym
          node[symbol_key] if node.has_key?(symbol_key)
        end

        def parse(body)
          return body if body.is_a?(Hash)

          body.present? ? JSON.parse(body) : {}
        rescue JSON::ParserError
          {}
        end

        # Normalises an arbitrary phone string to a bare MSISDN (digits only,
        # no leading "+") as required by Infobip's API.
        #
        # Rules applied in order:
        #   1. Strip everything except digits and a leading "+".
        #   2. Blank/empty input is returned as-is (let the API surface the error).
        #   3. "+CC…"     → drop the "+"     (e.g. "+3876XXXXXXX" → "3876XXXXXXX")
        #   4. "00CC…"    → drop the "00"    (e.g. "003876XXXXXXX" → "3876XXXXXXX")
        #   5. "387…"     → keep as-is       (already international)
        #   6. "0…"       → replace leading "0" with country_code
        #                   (e.g. "06XXXXXXX" → "3876XXXXXXX")
        #   7. Otherwise  → prepend country_code
        #                   (e.g. "6XXXXXXX" → "3876XXXXXXX")
        #
        # SINGLE-TENANT ASSUMPTION: the default country code is read from
        # Decidim::Bih::Config (ENV BIH_DEFAULT_COUNTRY_CODE, default "387").
        # A non-BiH international number typed WITHOUT a "+" prefix and not
        # starting with "387" will be mis-prefixed — this is an acceptable
        # trade-off for this deployment. Numbers entered with "+" (or "00" or
        # the full "387" prefix) are always normalised correctly.
        def normalize_msisdn(number)
          # Step 1: strip everything except digits and a leading "+".
          s = number.to_s.gsub(/(?!^)\+|[^\d+]/, "")
          return s if s.blank?

          cc = Decidim::Bih::Config.default_country_code

          # Step 3: "+CC…" → drop the "+"
          return s[1..] if s.start_with?("+")

          # Step 4: "00CC…" → drop the "00"
          return s[2..] if s.start_with?("00")

          # Step 5: already international (starts with country code)
          return s if s.start_with?(cc)

          # Step 6: local with leading "0" (e.g. "06XXXXXXX")
          return "#{cc}#{s[1..]}" if s.start_with?("0")

          # Step 7: bare national number (e.g. "6XXXXXXX")
          "#{cc}#{s}"
        end

        def infobip_channel(path)
          return "messages" if path.to_s.include?("messages-api")
          return "messenger" if path.to_s.include?("/messenger/")
          return "viber" if path.to_s.include?("viber")

          "sms"
        end

        def connection
          @connection ||= Faraday.new(url: base_url) do |f|
            f.options.timeout = @timeout
            f.options.open_timeout = @timeout
            f.adapter Faraday.default_adapter
          end
        end
      end
    end
  end
end
