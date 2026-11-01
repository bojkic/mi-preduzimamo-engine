# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../../../../app/services/decidim/bih/infobip/inbound_message"

module Decidim
  module Bih
    module Infobip
      class InboundMessageTest < Minitest::Test
        def test_parses_instagram_flat_push_and_preserves_reply_identity_and_time
          payload = JSON.parse(<<~JSON)
            {"results":[{"from":"xxx","to":"yyy","text":"example-text","cleanText":"stripped-text","keyword":null,"receivedAt":"2025-06-18T06:36:35.419+0000","smsCount":1,"messageId":"unique-message-id","pairedMessageId":null,"price":{"pricePerMessage":0.000000,"currency":"MYR"},"callbackData":null}],"messageCount":1,"pendingMessageCount":3}
          JSON
          messages = InboundMessage.parse_all(payload, route_channel: :instagram)
          assert_equal 1, messages.size
          message = messages.first
          assert_equal "example-text", message.text
          assert_equal "TEXT", message.type
          assert_equal "xxx", message.sender
          assert_equal "yyy", message.recipient
          assert_equal "unique-message-id", message.message_id
          assert_equal "2025-06-18T06:36:35.419000Z", message.occurred_at.utc.iso8601(6)
          primitives = message.to_primitives
          assert_equal primitives, InboundMessage.from_primitives(primitives).to_primitives
          refute_includes JSON.generate(primitives), "price"
          refute_includes JSON.generate(primitives), "cleanText"
        end

        def test_instagram_flat_text_keeps_nested_content_precedence
          payload = { from: "user", to: "business", messageId: "flat", text: "outer" }
          [{ message: { text: "native" } }, { content: [{ text: "native" }] }].each do |nested|
            message = InboundMessage.parse(payload.merge(nested), route_channel: :instagram)
            assert_equal "native", message.text
          end
        end

        def test_instagram_flat_text_keeps_bounds_and_channel_event_identity_checks
          payload = { from: "user", to: "business", messageId: "flat", text: "x" * 5000 }
          message = InboundMessage.parse(payload, route_channel: :instagram)
          assert_equal InboundMessage::MAX_TEXT_BYTES, message.text.bytesize
          [{ channel: "SMS" }, { event: "SEEN" }, { messageId: nil }, { from: nil }].each do |invalid|
            assert_nil InboundMessage.parse(payload.merge(invalid), route_channel: :instagram)
          end
          assert_nil InboundMessage.parse(payload, route_channel: :messenger).text
        end

        def test_preserves_original_provider_time_across_durable_serialization
          occurred = Time.now.utc - (25 * 3600)
          payload = result(channel: "MESSENGER", id: "old-message").merge("receivedAt" => occurred.iso8601(6))
          message = InboundMessage.parse(payload, route_channel: "messenger")
          restored = InboundMessage.from_primitives(message.to_primitives)
          assert_in_delta occurred.to_f, restored.occurred_at.to_f, 0.001
        end

        def test_missing_invalid_and_future_times_do_not_open_a_session
          [nil, "invalid", (Time.now.utc + 60).iso8601, 123_456].each do |value|
            message = InboundMessage.parse(result(channel: "MESSENGER", id: "bad-time").merge("receivedAt" => value), route_channel: "messenger")
            assert_nil message.occurred_at
          end
        end

        def test_parses_batches_and_prefers_contact_user_id_for_whatsapp
          payload = {
            "results" => [
              {
                "from" => "38765123456",
                "to" => "configured-whatsapp-sender",
                "integrationType" => "WHATSAPP",
                "messageId" => "message-1",
                "message" => { "type" => "TEXT", "text" => "Dobar dan" },
                "contact" => {
                  "userId" => "BA.opaque-business-scoped-user",
                  "name" => "Must never serialize",
                  "username" => "private.handle"
                }
              },
              {
                "from" => "fallback-opaque-sender",
                "to" => "configured-whatsapp-sender",
                "integrationType" => "WHATSAPP",
                "messageId" => "message-2",
                "message" => { "type" => "TEXT", "text" => "Treba mi pomoc" }
              }
            ]
          }

          messages = InboundMessage.parse_all(payload, route_channel: :whatsapp)

          assert_equal 2, messages.size
          assert_equal "BA.opaque-business-scoped-user", messages.first.sender
          assert_equal "fallback-opaque-sender", messages.last.sender
          assert_equal "configured-whatsapp-sender", messages.first.recipient
          assert_equal "Dobar dan", messages.first.text
          assert_equal "whatsapp", messages.first.channel
        end

        def test_filters_payload_items_that_do_not_match_the_route_channel
          payload = {
            "results" => [
              result(channel: "MESSENGER", id: "messenger-1"),
              result(channel: "INSTAGRAM", id: "instagram-1")
            ]
          }

          messages = InboundMessage.parse_all(payload, route_channel: "messenger")

          assert_equal ["messenger-1"], messages.map(&:message_id)
          assert_nil InboundMessage.parse(payload, route_channel: "whatsapp")
          assert_empty InboundMessage.parse_all(payload, route_channel: "unknown")
        end

        def test_accepts_direct_symbol_key_payload_and_location_aliases
          message = InboundMessage.parse(
            {
              sender: "opaque-instagram-user",
              to: "instagram-business",
              message_id: "instagram-message-1",
              message: {
                type: "LOCATION",
                text: "Ovdje je problem",
                coordinates: { lat: "44.756", lon: "19.214" }
              }
            },
            route_channel: :instagram
          )

          assert_equal "instagram", message.channel
          assert message.location?
          assert_in_delta 44.756, message.latitude
          assert_in_delta 19.214, message.longitude
        end

        def test_primitive_round_trip_excludes_raw_contact_and_provider_metadata
          message = InboundMessage.parse(
            result(channel: "WHATSAPP", id: "message-3").merge(
              "contact" => { "userId" => "BA.stable-id", "name" => "Private name", "username" => "private" },
              "referral" => { "sourceUrl" => "https://private.example/referral" }
            ),
            route_channel: :whatsapp
          )

          primitives = message.to_primitives
          serialized = primitives.to_s
          restored = InboundMessage.from_primitives(primitives)

          refute_includes serialized, "Private name"
          refute_includes serialized, "private.example"
          refute_includes serialized, "username"
          refute primitives.has_key?("raw")
          assert_equal primitives, restored.to_primitives
        end

        def test_skips_missing_or_oversized_idempotency_and_identity_values
          missing_id = result(channel: "WHATSAPP", id: nil)
          missing_sender = result(channel: "WHATSAPP", id: "message-4").tap { |item| item.delete("from") }
          oversized_sender = result(channel: "WHATSAPP", id: "message-5", sender: "s" * 256)
          oversized_id = result(channel: "WHATSAPP", id: "m" * 256)

          [missing_id, missing_sender, oversized_sender, oversized_id].each do |item|
            assert_empty InboundMessage.parse_all(item, route_channel: :whatsapp)
          end
        end

        def test_bounds_text_and_drops_an_overlong_media_url
          payload = result(channel: "INSTAGRAM", id: "message-6")
          payload["message"] = {
            "type" => "IMAGE",
            "text" => "x" * (InboundMessage::MAX_TEXT_BYTES + 20),
            "url" => "https://example.test/#{"x" * InboundMessage::MAX_MEDIA_URL_BYTES}"
          }

          message = InboundMessage.parse(payload, route_channel: :instagram)

          assert_equal InboundMessage::MAX_TEXT_BYTES, message.text.bytesize
          assert_nil message.image_url
          assert_operator JSON.generate(message.to_primitives).bytesize, :<, 5000
        end

        def test_drops_non_finite_and_out_of_range_coordinates
          payload = result(channel: "INSTAGRAM_DM", id: "message-coordinate")
          payload["message"] = {
            "type" => "LOCATION",
            "location" => { "latitude" => 91, "longitude" => Float::INFINITY }
          }

          message = InboundMessage.parse(payload, route_channel: :instagram)

          refute message.location?
          assert_nil message.latitude
          assert_nil message.longitude
        end

        def test_caps_one_webhook_batch_before_normalization
          payload = {
            "results" => 2005.times.map do |index|
              result(channel: "WHATSAPP", id: "message-#{index}")
            end
          }

          messages = InboundMessage.parse_all(payload, route_channel: :whatsapp)

          assert_equal InboundMessage::MAX_BATCH_RESULTS, messages.size
          assert_equal "message-1999", messages.last.message_id
        end

        def test_parses_official_messages_api_v2_envelope
          payload = {
            "results" => [{
              "channel" => "INSTAGRAM_DM",
              "sender" => "opaque-instagram-citizen",
              "destination" => "instagram-business",
              "content" => [{ "type" => "TEXT", "text" => "Dobar dan" }],
              "messageId" => "instagram-v2-1",
              "event" => "MO"
            }]
          }

          message = InboundMessage.parse(payload, route_channel: :instagram)

          assert_equal "instagram", message.channel
          assert_equal "opaque-instagram-citizen", message.sender
          assert_equal "instagram-business", message.recipient
          assert_equal "instagram-v2-1", message.message_id
          assert_equal "TEXT", message.type
          assert_equal "Dobar dan", message.text
        end

        def test_consolidates_mixed_v2_content_into_one_idempotent_receipt
          payload = {
            "results" => [{
              "channel" => "WHATSAPP",
              "sender" => "opaque-whatsapp-citizen",
              "destination" => "whatsapp-business",
              "content" => [
                { "type" => "FILE", "url" => "https://media.example.test/problem.jpg" },
                { "type" => "TEXT", "caption" => "Ne radi rasvjeta" },
                { "type" => "LOCATION", "latitude" => 44.756, "longitude" => 19.214 },
                { "type" => "FILE", "url" => "https://media.example.test/ignored.jpg", "text" => "Kasnije" }
              ],
              "messageId" => "whatsapp-v2-mixed-1",
              "event" => "MO"
            }]
          }

          messages = InboundMessage.parse_all(payload, route_channel: :whatsapp)
          assert_equal 1, messages.size
          message = messages.first

          assert_equal "whatsapp-v2-mixed-1", message.message_id
          assert_equal "Ne radi rasvjeta", message.text
          assert_nil message.image_url
          assert_in_delta 44.756, message.latitude
          assert_in_delta 19.214, message.longitude
        end

        def test_exposes_only_actual_image_url_from_mixed_v2_content
          payload = {
            "channel" => "WHATSAPP",
            "sender" => "opaque-whatsapp-citizen",
            "destination" => "whatsapp-business",
            "content" => [
              { "type" => "VIDEO", "url" => "https://media.example.test/problem.mp4" },
              { "type" => "IMAGE", "url" => "https://media.example.test/problem.jpg" }
            ],
            "messageId" => "whatsapp-v2-image-1",
            "event" => "MO"
          }

          message = InboundMessage.parse(payload, route_channel: :whatsapp)

          assert_equal "IMAGE", message.type
          assert_equal "https://media.example.test/problem.jpg", message.image_url
        end

        def test_preserves_official_v2_non_image_captions_without_an_image_signal
          content = [
            { "type" => "VIDEO", "url" => "https://media.example.test/problem.mp4", "text" => "Video caption" },
            { "type" => "DOCUMENT", "url" => "https://media.example.test/problem.pdf", "text" => "Document caption" },
            { "type" => "FILE", "url" => "https://media.example.test/problem.bin", "text" => "File caption" }
          ]

          content.each_with_index do |item, index|
            message = InboundMessage.parse(
              {
                "channel" => "WHATSAPP",
                "sender" => "opaque-whatsapp-citizen",
                "destination" => "whatsapp-business",
                "content" => [item],
                "messageId" => "whatsapp-v2-non-image-#{index}",
                "event" => "MO"
              },
              route_channel: :whatsapp
            )

            assert_equal item.fetch("type"), message.type
            assert_equal item.fetch("text"), message.text
            assert_nil message.image_url
          end
        end

        def test_bounds_v2_content_component_scanning
          content = Array.new(InboundMessage::MAX_CONTENT_ITEMS) { { "type" => "UNKNOWN" } }
          content << { "type" => "TEXT", "text" => "outside-bound" }
          payload = {
            "channel" => "INSTAGRAM_DM",
            "sender" => "opaque-instagram-citizen",
            "destination" => "instagram-business",
            "content" => content,
            "messageId" => "instagram-v2-bounded-content",
            "event" => "MO"
          }

          message = InboundMessage.parse(payload, route_channel: :instagram)

          assert_equal "instagram-v2-bounded-content", message.message_id
          assert_nil message.text
        end

        def test_parses_native_messenger_mid_and_ignores_non_message_v2_events
          native = {
            "results" => [{
              "sender" => "opaque-messenger-citizen",
              "to" => "messenger-page",
              "integrationType" => "FACEBOOK",
              "message" => { "mid" => "messenger-native-1", "type" => "TEXT", "text" => "Zdravo" }
            }]
          }
          typing = {
            "results" => [{
              "channel" => "MESSENGER",
              "sender" => "opaque-messenger-citizen",
              "destination" => "messenger-page",
              "messageId" => "typing-1",
              "event" => "TYPING_STARTED"
            }]
          }

          message = InboundMessage.parse(native, route_channel: :messenger)

          assert_equal "messenger-native-1", message.message_id
          assert_equal "Zdravo", message.text
          assert_empty InboundMessage.parse_all(typing, route_channel: :messenger)
        end

        def test_preserves_native_messenger_phone_quick_reply_as_text
          payload = {
            "results" => [{
              "sender" => "opaque-messenger-citizen",
              "to" => "messenger-page",
              "integrationType" => "FACEBOOK",
              "message" => {
                "mid" => "messenger-phone-quick-reply-1",
                "type" => "TEXT",
                "text" => "+38765123456",
                "quickReply" => { "payload" => "opaque-provider-payload" }
              }
            }]
          }

          message = InboundMessage.parse(payload, route_channel: :messenger)

          assert_equal "messenger-phone-quick-reply-1", message.message_id
          assert_equal "+38765123456", message.text
        end

        def test_parses_official_native_whatsapp_media_caption
          payload = {
            "results" => [{
              "from" => "38765123456",
              "to" => "configured-whatsapp-sender",
              "integrationType" => "WHATSAPP",
              "messageId" => "whatsapp-native-image-1",
              "message" => {
                "type" => "IMAGE",
                "url" => "https://media.example.test/problem.jpg",
                "caption" => "Ne radi rasvjeta"
              }
            }]
          }

          message = InboundMessage.parse(payload, route_channel: :whatsapp)

          assert_equal "whatsapp-native-image-1", message.message_id
          assert_equal "Ne radi rasvjeta", message.text
          assert_equal "https://media.example.test/problem.jpg", message.image_url
        end

        def test_preserves_official_native_whatsapp_video_and_document_captions_without_an_image_signal
          [
            ["VIDEO", "https://media.example.test/problem.mp4", "Video caption"],
            ["DOCUMENT", "https://media.example.test/problem.pdf", "Document caption"]
          ].each_with_index do |(type, url, caption), index|
            payload = {
              "results" => [{
                "from" => "38765123456",
                "to" => "configured-whatsapp-sender",
                "integrationType" => "WHATSAPP",
                "messageId" => "whatsapp-native-non-image-#{index}",
                "message" => { "type" => type, "url" => url, "caption" => caption }
              }]
            }

            message = InboundMessage.parse(payload, route_channel: :whatsapp)

            assert_equal type, message.type
            assert_equal caption, message.text
            assert_nil message.image_url
          end
        end

        def test_preserves_bounded_media_description_without_an_image_signal
          payload = result(channel: "INSTAGRAM_DM", id: "instagram-video-description")
          payload["message"] = {
            "type" => "VIDEO",
            "url" => "https://media.example.test/problem.mp4",
            "description" => "x" * (InboundMessage::MAX_TEXT_BYTES + 20)
          }

          message = InboundMessage.parse(payload, route_channel: :instagram)

          assert_equal InboundMessage::MAX_TEXT_BYTES, message.text.bytesize
          assert_nil message.image_url
        end

        private

        def result(channel:, id:, sender: "opaque-citizen")
          {
            "from" => sender,
            "to" => "configured-business-sender",
            "integrationType" => channel,
            "messageId" => id,
            "message" => { "type" => "TEXT", "text" => "Zdravo" }
          }
        end
      end
    end
  end
end
