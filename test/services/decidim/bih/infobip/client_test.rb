# frozen_string_literal: true

require "test_helper"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/log_redactor"
require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/infobip/client"

module Decidim
  module Bih
    module Infobip
      class ClientTest < Minitest::Test
        ENV_KEYS = %w(
          INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_CHAT_CHANNELS INFOBIP_WHATSAPP_SENDER
          INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE
          INFOBIP_VIBER_BM_SENDER INFOBIP_SMS_SENDER INFOBIP_MESSAGES_API_ENABLED
          INFOBIP_MESSENGER_SENDER INFOBIP_INSTAGRAM_SENDER
        ).freeze

        def setup
          @original_env = ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
          ENV_KEYS.each { |key| ENV.delete(key) }
          Config.reset!
        end

        def teardown
          @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Config.reset!
        end

        def test_config_parses_only_explicit_supported_chat_channels_and_instagram_sender
          ENV["INFOBIP_CHAT_CHANNELS"] = " WhatsApp,instagram,UNKNOWN,whatsapp "
          ENV["INFOBIP_INSTAGRAM_SENDER"] = "instagram-business"

          config = Config.infobip

          assert_equal %w(whatsapp instagram), config[:chat_channels]
          assert_equal "instagram-business", config[:instagram_sender]
        end

        def test_whatsapp_auth_defaults_to_approved_serbian_template_language
          configure_credentials
          ENV["INFOBIP_WHATSAPP_SENDER"] = "whatsapp-business"
          ENV["INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME"] = "mi_verifikacija_kod_v1"
          Config.reset!

          assert_equal "sr", Config::WHATSAPP_AUTH_TEMPLATE_LANGUAGE
          assert_equal Config::WHATSAPP_AUTH_TEMPLATE_LANGUAGE, Config.infobip[:whatsapp_template_language]
          assert Config.whatsapp_phone_auth_configured?

          ENV["INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE"] = "bs"
          Config.reset!
          refute Config.whatsapp_phone_auth_configured?
        end

        def test_sender_configuration_alone_does_not_enable_a_chat_channel
          configure_credentials
          ENV["INFOBIP_WHATSAPP_SENDER"] = "whatsapp-business"
          Config.reset!

          refute Client.new.chat_channel_configured?(:whatsapp)

          ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp"
          Config.reset!

          assert Client.new.chat_channel_configured?("whatsapp")
        end

        def test_sends_session_text_without_normalizing_opaque_recipient
          configure_chat("whatsapp", sender: "whatsapp-business")
          client = Client.new
          captured = nil

          post = lambda do |path, body|
            captured = [path, body]
            { "status" => "accepted" }
          end
          client.stub(:post, post) do
            client.send_chat_text(
              channel: :whatsapp,
              to: "BA.opaque-business-scoped-user",
              text: "Odgovor"
            )
          end

          assert_equal Client::MESSAGES_API_PATH, captured.first
          message = captured.last.fetch(:messages).sole
          assert_equal "WHATSAPP", message.fetch(:channel)
          assert_equal "whatsapp-business", message.fetch(:sender)
          assert_equal [{ to: "BA.opaque-business-scoped-user" }], message.fetch(:destinations)
          assert_equal({ body: { type: "TEXT", text: "Odgovor" } }, message.fetch(:content))
          assert_equal({ adaptationMode: false }, message.fetch(:options))
        end

        def test_uses_channel_specific_codes_and_senders
          {
            "messenger" => ["MESSENGER", "messenger-business"],
            "instagram" => ["INSTAGRAM_DM", "instagram-business"]
          }.each do |channel, (code, sender)|
            configure_chat(channel, sender:)
            captured = nil

            post = lambda do |_path, body|
              captured = body
              {}
            end
            Client.new.stub(:post, post) do |client|
              client.send_chat_text(channel:, to: "opaque-user", text: "Zdravo")
            end

            message = captured.fetch(:messages).sole
            assert_equal code, message.fetch(:channel)
            assert_equal sender, message.fetch(:sender)
          end
        end

        def test_native_messenger_phone_request_matches_offline_provider_contract
          configure_chat("messenger", sender: "messenger-page")
          captured = nil
          prompt = "Podijeli broj telefona ili ga upiši ručno."

          poster = lambda do |path, body|
            captured = [path, body]
            {}
          end
          Client.new.stub(:post, poster) do |client|
            client.send_chat_text(
              channel: "messenger",
              to: "opaque-messenger-user",
              text: prompt,
              request_phone: true
            )
          end

          contract = JSON.parse(
            File.read(File.expand_path("../../../../fixtures/infobip/messenger_phone_request_contract.json", __dir__))
          )
          message = captured.last.fetch(:messages).sole

          assert_equal contract.fetch("path"), captured.first
          assert_empty(contract.dig("request", "required") - captured.last.keys.map(&:to_s))
          assert_empty(contract.dig("message", "required") - message.keys.map(&:to_s))
          assert_empty(message.keys.map(&:to_s) - contract.dig("message", "properties"))
          assert_equal "messenger-page", message.fetch(:sender)
          assert_equal [{ to: "opaque-messenger-user" }], message.fetch(:destinations)
          assert_equal({ type: "TEXT", text: prompt }, message.fetch(:content))
          assert_empty(contract.dig("content", "required") - message.fetch(:content).keys.map(&:to_s))
          assert_operator prompt.length, :<=, contract.dig("content", "text_max_length")
          assert_equal [{ type: "PHONE_NUMBER" }], message.fetch(:quickReplies)
          assert_includes contract.dig("quick_reply", "type_enum"), message.dig(:quickReplies, 0, :type)
          refute message.has_key?(:channel)
          assert_equal "messenger", Client.new.send(:infobip_channel, captured.first)
        end

        def test_phone_request_rejects_non_messenger_and_non_boolean_values_without_posting
          configure_chat("instagram", sender: "instagram-business")
          client = Client.new
          posted = false

          client.stub(:post, ->(*) { posted = true }) do
            assert_raises(Error) do
              client.send_chat_text(channel: "instagram", to: "opaque-user", text: "Broj?", request_phone: true)
            end
            assert_raises(Error) do
              client.send_chat_text(channel: "instagram", to: "opaque-user", text: "Broj?", request_phone: "true")
            end
          end

          refute posted
        end

        def test_native_messenger_definitive_rejection_falls_back_to_plain_unified_text
          configure_chat("messenger", sender: "messenger-page")
          assert_equal [400, 401, 403, 404, 422], Client::MESSENGER_NATIVE_FALLBACK_STATUSES

          Client::MESSENGER_NATIVE_FALLBACK_STATUSES.each do |status|
            calls = []
            poster = lambda do |path, body|
              calls << [path, body]
              raise Error.new("native unsupported", http_status: status) if path == Client::MESSENGER_PHONE_REQUEST_PATH

              { "status" => "accepted" }
            end
            Client.new.stub(:post, poster) do |client|
              client.send_chat_text(
                channel: "messenger",
                to: "opaque-user",
                text: "Podijeli broj ili ga upiši ručno.",
                request_phone: true
              )
            end

            assert_equal [Client::MESSENGER_PHONE_REQUEST_PATH, Client::MESSAGES_API_PATH], calls.map(&:first)
            fallback = calls.last.last.fetch(:messages).sole
            assert_equal "MESSENGER", fallback.fetch(:channel)
            assert_equal(
              { body: { type: "TEXT", text: "Podijeli broj ili ga upiši ručno." } },
              fallback.fetch(:content)
            )
            refute fallback.has_key?(:quickReplies)
          end
        end

        def test_native_messenger_ambiguous_failure_does_not_fallback
          configure_chat("messenger", sender: "messenger-page")
          paths = []

          error = Client.new.stub(:post, lambda { |path, _body|
            paths << path
            raise Error.new("provider unavailable", http_status: 500)
          }) do |client|
            assert_raises(Error) do
              client.send_chat_text(
                channel: "messenger", to: "opaque-user", text: "Broj?", request_phone: true
              )
            end
          end

          assert_equal [Client::MESSENGER_PHONE_REQUEST_PATH], paths
          assert_equal "Infobip messenger chat delivery failed", error.message
          assert_equal 500, error.http_status
        end

        def test_native_messenger_failed_plain_fallback_keeps_sanitized_error
          configure_chat("messenger", sender: "messenger-page")
          calls = 0

          error = Client.new.stub(:post, lambda { |path, _body|
            calls += 1
            status = path == Client::MESSENGER_PHONE_REQUEST_PATH ? 400 : 403
            raise Error.new("provider leaked opaque-user", http_status: status, error_code: "REJECTED")
          }) do |client|
            assert_raises(Error) do
              client.send_chat_text(
                channel: "messenger", to: "opaque-user", text: "Broj?", request_phone: true
              )
            end
          end

          assert_equal 2, calls
          assert_equal "Infobip messenger chat delivery failed", error.message
          assert_equal 403, error.http_status
          assert_equal "REJECTED", error.error_code
          assert_nil error.cause
          refute_includes error.message, "opaque-user"
        end

        def test_sends_provider_safe_chat_image_with_common_messages_api_body
          configure_chat("instagram", sender: "instagram-business")
          captured = nil

          poster = lambda do |path, body|
            captured = [path, body]
            {}
          end
          Client.new.stub(:post, poster) do |client|
            client.send_chat_image(
              channel: "instagram",
              to: "opaque-instagram-user",
              image_url: "https://mi.example.test/mi/milica/wave.jpg"
            )
          end

          assert_equal Client::MESSAGES_API_PATH, captured.first
          message = captured.last.fetch(:messages).sole
          assert_equal "INSTAGRAM_DM", message.fetch(:channel)
          assert_equal "instagram-business", message.fetch(:sender)
          assert_equal [{ to: "opaque-instagram-user" }], message.fetch(:destinations)
          assert_equal(
            { body: { type: "IMAGE", url: "https://mi.example.test/mi/milica/wave.jpg" } },
            message.fetch(:content)
          )
          assert_equal({ adaptationMode: false }, message.fetch(:options))
        end

        def test_chat_image_rejects_non_https_userinfo_and_unbounded_caption
          configure_chat("whatsapp", sender: "whatsapp-business")
          client = Client.new

          assert_raises(Error) do
            client.send_chat_image(channel: "whatsapp", to: "opaque", image_url: "http://mi.example.test/wave.jpg")
          end
          assert_raises(Error) do
            client.send_chat_image(channel: "whatsapp", to: "opaque", image_url: "https://user@mi.example.test/wave.jpg")
          end
          assert_raises(Error) do
            client.send_chat_image(
              channel: "whatsapp", to: "opaque", image_url: "https://mi.example.test/wave.jpg", text: "x" * 1025
            )
          end
        end

        def test_viber_bot_outbound_uses_singular_messages_api_channel_and_opaque_recipient
          captured = nil
          client = Client.new

          client.stub(:post, ->(path, body) { captured = [path, body] }) do
            client.send_viber_bot(
              to: "opaque-viber-bot-user",
              text: "Zdravo",
              sender: "configured-viber-bot"
            )
          end

          assert_equal Client::MESSAGES_API_PATH, captured.first
          message = captured.last.fetch(:messages).first
          assert_equal "VIBER_BOT", message.fetch(:channel)
          assert_equal "configured-viber-bot", message.fetch(:sender)
          assert_equal [{ to: "opaque-viber-bot-user" }], message.fetch(:destinations)
          assert_equal({ body: { type: "TEXT", text: "Zdravo" } }, message.fetch(:content))
        end

        def test_rejects_unsupported_disabled_and_incomplete_channels
          configure_credentials
          Config.reset!
          client = Client.new

          assert_raises(Error) { client.send_chat_text(channel: :viber, to: "opaque", text: "Zdravo") }
          assert_raises(Error) { client.send_chat_text(channel: :whatsapp, to: "opaque", text: "Zdravo") }

          ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp"
          Config.reset!
          assert_raises(Error) { client.send_chat_text(channel: :whatsapp, to: "opaque", text: "Zdravo") }
        end

        def test_auth_messages_api_payload_uses_code_only_and_excludes_messenger
          configure_phone_delivery(messages_api: true, viber: "viber-business", whatsapp: "whatsapp-business")
          captured = nil
          client = Client.new

          client.stub(:post, lambda do |path, body|
            captured = [path, body]
            { "status" => "accepted" }
          end) do
            client.send_phone_message(
              to: "+38765123456",
              text: "SMS link https://example.test/v/private-token and code 123456",
              viber_text: "Viber link https://example.test/v/private-token",
              expires_at: 10.minutes.from_now,
              messenger: { to: "private-messenger", session_active: true },
              otp_code: "123456"
            )
          end

          assert_equal Client::MESSAGES_API_PATH, captured.first
          message = captured.last.fetch(:messages).sole
          assert_equal [
            { channel: "VIBER_BM", to: "38765123456" },
            { channel: "WHATSAPP", to: "38765123456" },
            { channel: "SMS", to: "38765123456" }
          ], message.fetch(:destinations).sole.fetch(:byChannel)

          whatsapp = message.fetch(:failover).first
          assert_equal "WHATSAPP", whatsapp.fetch(:channel)
          assert_equal(
            { templateName: "mi_verifikacija_kod_v1", language: "sr" },
            whatsapp.fetch(:template)
          )
          assert_equal(
            { body: { "1" => "123456", "type" => "TEXT" }, buttons: [{ suffix: "123456", type: "OPEN_URL" }] },
            whatsapp.fetch(:content)
          )
          refute_includes whatsapp.to_json, "private-token"
          refute_includes whatsapp.to_json, "SMS link"
          refute_includes message.to_json, "private-messenger"
        end

        def test_link_only_call_skips_whatsapp_even_when_sender_and_template_exist
          configure_phone_delivery(messages_api: true, viber: "viber-business", whatsapp: "whatsapp-business")
          captured = nil

          Client.new.stub(:post, lambda do |_path, body|
            captured = body
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Link https://example.test/v/private-token",
              viber_text: "Link https://example.test/v/private-token"
            )
          end

          message = captured.fetch(:messages).sole
          channels = message.fetch(:destinations).sole.fetch(:byChannel).map { |entry| entry.fetch(:channel) }
          assert_equal %w(VIBER_BM SMS), channels
          assert_equal "VIBER_BM", message.fetch(:channel)
          assert_equal "SMS", message.fetch(:failover).sole.fetch(:channel)
        end

        def test_sms_only_bypasses_messages_api_and_messenger
          configure_phone_delivery(messages_api: true)
          captured = []

          Client.new.stub(:post, lambda do |path, body|
            captured << [path, body]
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Link https://example.test/v/private-token",
              messenger: { to: "private-messenger", session_active: true }
            )
          end

          assert_equal 1, captured.size
          assert_equal "/sms/2/text/advanced", captured.first.first
          assert_equal "38765123456", captured.first.last.dig(:messages, 0, :destinations, 0, :to)
        end

        def test_requested_sms_subset_skips_configured_viber_and_whatsapp
          configure_phone_delivery(messages_api: true, viber: "viber-business", whatsapp: "whatsapp-business")
          paths = []

          Client.new.stub(:post, lambda do |path, _body|
            paths << path
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Link https://example.test/v/private-token",
              channels: [:sms],
              otp_code: "123456"
            )
          end

          assert_equal ["/sms/2/text/advanced"], paths
        end

        def test_requested_channel_subset_requires_order_and_final_sms
          configure_phone_delivery(messages_api: false, viber: "viber-business")
          client = Client.new

          assert_raises(Error) do
            client.send_phone_message(to: "065123456", text: "t", channels: [:viber])
          end
          assert_raises(Error) do
            client.send_phone_message(to: "065123456", text: "t", channels: [:sms, :viber])
          end
          assert_raises(Error) do
            client.send_phone_message(to: "065123456", text: "t", channels: [:messenger, :sms])
          end
          assert_raises(Error) do
            client.send_phone_message(to: "065123456", text: "t", channels: [:sms, :sms])
          end
        end

        def test_messages_api_disabled_keeps_native_viber_to_sms_failover
          configure_phone_delivery(messages_api: false, viber: "viber-business", whatsapp: "whatsapp-business")
          calls = []
          client = Client.new

          client.stub(:send_viber_business, lambda do |**attributes|
            calls << attributes
            {}
          end) do
            client.stub(:post, lambda do |*args|
              calls << args
              {}
            end) do
              client.send_phone_message(
                to: "065123456",
                text: "Link https://example.test/v/private-token; code 123456",
                viber_text: "Link https://example.test/v/private-token",
                otp_code: "123456"
              )
            end
          end

          assert_equal 1, calls.size
          assert_equal "Link https://example.test/v/private-token", calls.first.fetch(:text)
          assert_equal "065123456", calls.first.fetch(:to)
          assert_equal "Link https://example.test/v/private-token; code 123456", calls.first.dig(:sms_failover, :text)
        end

        def test_chat_delivery_error_does_not_echo_provider_body_or_recipient
          configure_chat("whatsapp", sender: "whatsapp-business")
          client = Client.new

          error = client.stub(
            :post,
            lambda do |*|
              raise Error.new(
                "HTTP 429 userId=BA.private-recipient text=Private citizen reply",
                http_status: 429,
                error_code: "RATE_LIMITED",
                error_group: "REJECTED"
              )
            end
          ) do
            assert_raises(Error) do
              client.send_chat_text(
                channel: :whatsapp,
                to: "BA.private-recipient",
                text: "Private citizen reply"
              )
            end
          end

          assert_equal "Infobip whatsapp chat delivery failed", error.message
          assert_nil error.cause
          assert_equal 429, error.http_status
          assert_equal "RATE_LIMITED", error.error_code
          assert_equal "REJECTED", error.error_group
          refute_includes error.message, "BA.private-recipient"
          refute_includes error.message, "Private citizen reply"
        end

        def test_channels_sms_only_skips_viber_even_when_a_viber_sender_is_configured
          configure_phone_channels(sms_sender: "MIBN", viber_bm_sender: "MIBN")
          client = Client.new
          paths = []

          client.stub(:post, lambda { |path, _body|
            paths << path
            { "status" => "accepted" }
          }) do
            client.send_phone_message(to: "+38765123456", text: "t", viber_text: "v", channels: [:sms])
          end

          assert_equal ["/sms/2/text/advanced"], paths
        end

        # Decidim's MobilePhoneForm declares `attribute :delivery_channels,
        # [String]`, whose default is [] and not nil, so an empty subset rides
        # along on every stock registration SMS. It has to mean "no
        # restriction" — reading it as "no channels at all" would raise on the
        # single most common send this client makes.
        def test_empty_channel_subset_means_no_restriction
          configure_phone_channels(sms_sender: "MIBN", viber_bm_sender: "MIBN")
          client = Client.new
          paths = []

          client.stub(:post, lambda { |path, _body|
            paths << path
            { "status" => "accepted" }
          }) do
            client.send_phone_message(to: "+38765123456", text: "t", viber_text: "v", channels: [])
          end

          assert_equal ["/viber/2/messages"], paths,
                       "an empty subset keeps the full configured channel order"
        end

        def test_channels_without_sms_is_rejected
          configure_phone_channels(sms_sender: "MIBN", viber_bm_sender: "MIBN")
          client = Client.new

          assert_raises(Error) do
            client.send_phone_message(to: "+38765123456", text: "t", channels: [:viber])
          end
        end

        def test_non_success_response_extracts_only_allowlisted_error_fields
          body = {
            requestError: {
              serviceException: {
                messageId: "UNAUTHORIZED",
                text: "userId=BA.private-recipient"
              }
            },
            status: {
              groupName: "REJECTED",
              description: "Private citizen reply"
            },
            recipient: "BA.private-recipient"
          }.to_json
          response = error_response(status: 401, body:)

          error = assert_raises(Error) { Client.new.send(:handle, response) }

          assert_equal 401, error.http_status
          assert_equal "UNAUTHORIZED", error.error_code
          assert_equal "REJECTED", error.error_group
          refute_includes error.metadata.values, "BA.private-recipient"
          refute_includes error.metadata.values, "Private citizen reply"
        end

        # A message that is not a code reaches WhatsApp only through a
        # caller-named approved template: placeholders and the button suffix
        # travel, the SMS text (and the link inside it) never does.
        def test_named_template_puts_whatsapp_into_the_chain_without_an_otp
          configure_phone_delivery(messages_api: true, viber: "viber-business", whatsapp: "whatsapp-business")
          captured = nil

          Client.new.stub(:post, lambda do |_path, body|
            captured = body
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Rezervacija MI-ABCDE-FGHIJ, potvrdi: https://example.test/v/private-token",
              viber_text: "Rezervacija MI-ABCDE-FGHIJ, potvrdi: https://example.test/v/private-token",
              whatsapp_template: {
                name: "mi_pozivnica_lansiranje_v1",
                language: "sr",
                body: { "1" => "MI-ABCDE-FGHIJ" },
                button_suffix: "private-token"
              }
            )
          end

          message = captured.fetch(:messages).sole
          channels = message.fetch(:destinations).sole.fetch(:byChannel).map { |entry| entry.fetch(:channel) }
          assert_equal %w(VIBER_BM WHATSAPP SMS), channels

          whatsapp = message.fetch(:failover).find { |step| step.fetch(:channel) == "WHATSAPP" }
          assert_equal({ templateName: "mi_pozivnica_lansiranje_v1", language: "sr" }, whatsapp.fetch(:template))
          assert_equal(
            { body: { "1" => "MI-ABCDE-FGHIJ", "type" => "TEXT" }, buttons: [{ suffix: "private-token", type: "OPEN_URL" }] },
            whatsapp.fetch(:content)
          )
          refute_includes whatsapp.to_json, "https://example.test"
          refute_includes whatsapp.to_json, "Rezervacija"
        end

        def test_named_template_without_a_whatsapp_sender_is_ignored
          configure_phone_delivery(messages_api: true, viber: "viber-business")
          captured = nil

          Client.new.stub(:post, lambda do |_path, body|
            captured = body
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Rezervacija",
              whatsapp_template: { name: "mi_pozivnica_lansiranje_v1", language: "sr", body: { "1" => "x" } }
            )
          end

          channels = captured.fetch(:messages).sole.fetch(:destinations).sole.fetch(:byChannel).map { |entry| entry.fetch(:channel) }
          assert_equal %w(VIBER_BM SMS), channels
        end

        def test_an_otp_always_uses_the_auth_template_even_when_a_named_template_is_given
          configure_phone_delivery(messages_api: true, viber: "viber-business", whatsapp: "whatsapp-business")
          captured = nil

          Client.new.stub(:post, lambda do |_path, body|
            captured = body
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Kod 123456",
              otp_code: "123456",
              whatsapp_template: { name: "mi_pozivnica_lansiranje_v1", language: "sr", body: { "1" => "x" } }
            )
          end

          whatsapp = captured.fetch(:messages).sole.fetch(:failover).find { |step| step.fetch(:channel) == "WHATSAPP" }
          assert_equal "mi_verifikacija_kod_v1", whatsapp.fetch(:template).fetch(:templateName)
        end

        # A campaign message with no SMS text (final_sms: false) runs Viber ->
        # WhatsApp only: no SMS leg, one Messages API request, and a
        # configuration error is raised rather than degraded into an SMS.
        def test_final_sms_false_builds_a_chain_without_sms
          configure_phone_delivery(messages_api: true, viber: "viber-business", whatsapp: "whatsapp-business")
          captured = nil

          Client.new.stub(:post, lambda do |_path, body|
            captured = body
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Trka komšiluka, 21.9.",
              viber_text: "Trka komšiluka, 21.9.",
              whatsapp_template: { name: "mi_p9_trka_sedmica_v1", language: "sr", body: { "1" => "21.9." } },
              final_sms: false
            )
          end

          message = captured.fetch(:messages).sole
          channels = message.fetch(:destinations).sole.fetch(:byChannel).map { |entry| entry.fetch(:channel) }
          assert_equal %w(VIBER_BM WHATSAPP), channels
          assert_equal "WHATSAPP", message.fetch(:failover).sole.fetch(:channel)
        end

        def test_final_sms_false_with_a_single_channel_sends_one_request_without_failover
          configure_phone_delivery(messages_api: true, whatsapp: "whatsapp-business")
          captured = nil

          Client.new.stub(:post, lambda do |_path, body|
            captured = body
            {}
          end) do |client|
            client.send_phone_message(
              to: "065123456",
              text: "Imamo pobjednike",
              whatsapp_template: { name: "mi_p10_pobjednici_v1", language: "sr", body: { "1" => "Dašnica" } },
              final_sms: false
            )
          end

          message = captured.fetch(:messages).sole
          assert_equal "WHATSAPP", message.fetch(:channel)
          refute message.has_key?(:failover)
        end

        def test_final_sms_false_raises_instead_of_sending_an_sms_when_nothing_rich_is_configured
          configure_phone_delivery(messages_api: true)
          posted = false

          assert_raises(Error) do
            Client.new.stub(:post, ->(*) { posted = true }) do |client|
              client.send_phone_message(to: "065123456", text: "Hvala", viber_text: "Hvala", final_sms: false)
            end
          end
          refute posted
        end

        private

        def configure_credentials
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
        end

        def configure_phone_delivery(messages_api:, viber: nil, whatsapp: nil)
          configure_credentials
          ENV["INFOBIP_SMS_SENDER"] = "MI"
          ENV["INFOBIP_MESSAGES_API_ENABLED"] = messages_api.to_s
          ENV["INFOBIP_VIBER_BM_SENDER"] = viber if viber
          ENV["INFOBIP_WHATSAPP_SENDER"] = whatsapp if whatsapp
          ENV["INFOBIP_WHATSAPP_PHONE_TEMPLATE_NAME"] = "mi_verifikacija_kod_v1" if whatsapp
          ENV["INFOBIP_WHATSAPP_PHONE_TEMPLATE_LANGUAGE"] = "sr" if whatsapp
          Config.reset!
        end

        def configure_chat(channel, sender:)
          configure_credentials
          ENV["INFOBIP_CHAT_CHANNELS"] = channel
          ENV["INFOBIP_#{channel.upcase}_SENDER"] = sender
          Config.reset!
        end

        def configure_phone_channels(sms_sender:, viber_bm_sender: nil)
          configure_credentials
          ENV["INFOBIP_SMS_SENDER"] = sms_sender
          ENV["INFOBIP_VIBER_BM_SENDER"] = viber_bm_sender if viber_bm_sender
          Config.reset!
        end

        def error_response(status:, body:)
          Struct.new(:status, :body) do
            def success?
              false
            end
          end.new(status, body)
        end
      end
    end
  end
end
