# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../../../../app/services/decidim/bih/viber/inbound_message"

module Decidim
  module Bih
    module Viber
      class InboundMessageTest < Minitest::Test
        def test_parses_official_wrapped_viber_bot_message
          payload = {
            "results" => [{
              "sender" => "outer-opaque-viber-user",
              "to" => "configured-viber-bot",
              "integrationType" => "VIBER_BOTS",
              "messageId" => "viber-provider-1",
              "message" => {
                "type" => "MESSAGE",
                "messageToken" => "viber-token-1",
                "sender" => { "id" => "nested-opaque-viber-user", "name" => "Private name" },
                "message" => { "type" => "TEXT", "text" => "Dobar dan" }
              }
            }]
          }

          messages = InboundMessage.parse_all(payload)
          assert_equal 1, messages.size
          message = messages.first

          assert_equal "viber", message.channel
          assert_equal "nested-opaque-viber-user", message.sender
          assert_equal "configured-viber-bot", message.recipient
          assert_equal "viber-provider-1", message.message_id
          assert_equal "TEXT", message.type
          assert_equal "Dobar dan", message.text
          refute_includes message.to_primitives.to_s, "Private name"
        end

        def test_preserves_flattened_legacy_shape_and_primitives
          messages = InboundMessage.parse_all(
            "results" => [{
              "from" => "legacy-viber-user",
              "to" => "configured-viber-bot",
              "messageId" => "legacy-message-1",
              "message" => {
                "type" => "LOCATION",
                "text" => "Problem",
                "location" => { "latitude" => 44.75, "longitude" => 19.21 }
              }
            }]
          )
          assert_equal 1, messages.size
          message = messages.first

          restored = InboundMessage.from_primitives(message.to_primitives)

          assert_equal message.to_primitives, restored.to_primitives
          assert restored.location?
        end

        def test_parses_messages_api_v2_mo_content_and_destination
          payload = {
            "results" => [{
              "channel" => "VIBER_BOT",
              "sender" => "v2-opaque-viber-user",
              "destination" => "configured-viber-bot",
              "messageId" => "v2-provider-message-1",
              "event" => "MO",
              "content" => [{ "type" => "TEXT", "text" => "Dobar dan iz v2" }]
            }]
          }

          messages = InboundMessage.parse_all(payload)
          assert_equal 1, messages.size
          message = messages.first

          assert_equal "viber", message.channel
          assert_equal "v2-opaque-viber-user", message.sender
          assert_equal "configured-viber-bot", message.recipient
          assert_equal "v2-provider-message-1", message.message_id
          assert_equal "TEXT", message.type
          assert_equal "Dobar dan iz v2", message.text
        end

        def test_ignores_messages_api_v2_non_mo_events
          payload = {
            "results" => [{
              "channel" => "VIBER_BOT",
              "sender" => "v2-opaque-viber-user",
              "destination" => "configured-viber-bot",
              "messageId" => "v2-provider-message-2",
              "event" => "DELIVERY",
              "content" => [{ "type" => "TEXT", "text" => "Not a citizen message" }]
            }]
          }

          assert_empty InboundMessage.parse_all(payload)
        end

        def test_maps_only_a_narrow_official_conversation_started_verification_context
          result = official_result(id: "outer-conversation-1", event_type: "CONVERSATION_STARTED")
          result["sender"] = "outer-opaque-viber-user"
          result["message"] = {
            "type" => "CONVERSATION_STARTED",
            "messageToken" => "conversation-token-1",
            "user" => { "id" => "nested-opaque-viber-user", "name" => "Private name" },
            "context" => "verify_#{"a" * 32}",
            "subscribed" => true
          }

          messages = InboundMessage.parse_all("results" => [result])

          assert_equal 1, messages.size
          message = messages.first
          assert_equal "nested-opaque-viber-user", message.sender
          assert_equal "configured-viber-bot", message.recipient
          assert_equal "outer-conversation-1", message.message_id
          assert_equal "TEXT", message.type
          assert_equal "verify_#{"a" * 32}", message.text
          refute_includes message.to_primitives.to_s, "Private name"

          result["message"]["context"] = "show_news"
          assert_empty InboundMessage.parse_all("results" => [result])
          result["message"]["context"] = "verify_short"
          assert_empty InboundMessage.parse_all("results" => [result])
        end

        def test_consolidates_mixed_v2_content_without_deriving_component_ids
          payload = {
            "results" => [{
              "channel" => "VIBER_BOT",
              "sender" => "v2-opaque-viber-user",
              "destination" => "configured-viber-bot",
              "messageId" => "v2-provider-mixed-1",
              "event" => "MO",
              "content" => [
                { "type" => "IMAGE", "url" => "https://media.example.test/problem.jpg" },
                { "type" => "TEXT", "caption" => "Ne radi rasvjeta" },
                { "type" => "LOCATION", "latitude" => 44.756, "longitude" => 19.214 },
                { "type" => "IMAGE", "url" => "https://media.example.test/ignored.jpg", "text" => "Kasnije" }
              ]
            }]
          }

          messages = InboundMessage.parse_all(payload)
          assert_equal 1, messages.size
          message = messages.first

          assert_equal "v2-provider-mixed-1", message.message_id
          assert_equal "Ne radi rasvjeta", message.text
          assert_equal "https://media.example.test/problem.jpg", message.image_url
          assert_in_delta 44.756, message.latitude
          assert_in_delta 19.214, message.longitude
        end

        def test_accepts_only_actual_image_content_as_report_media
          native_video = official_result(id: "native-video-1")
          native_video["message"]["message"] = {
            "type" => "VIDEO",
            "url" => "https://media.example.test/private-video.mp4",
            "description" => "Opis videa"
          }
          v2_file = {
            "channel" => "VIBER_BOT",
            "sender" => "v2-opaque-viber-user",
            "destination" => "configured-viber-bot",
            "messageId" => "v2-file-1",
            "event" => "MO",
            "content" => [{ "type" => "FILE", "url" => "https://media.example.test/private-file.pdf" }]
          }
          v2_image = v2_file.merge(
            "messageId" => "v2-image-1",
            "content" => [{ "type" => "IMAGE", "url" => "https://media.example.test/problem.jpg" }]
          )

          messages = InboundMessage.parse_all("results" => [native_video, v2_file, v2_image])

          assert_equal [nil, nil, "https://media.example.test/problem.jpg"], messages.map(&:image_url)
          assert_equal %w(VIDEO FILE IMAGE), messages.map(&:type)
          assert_equal "Opis videa", messages.first.text
          refute_includes messages.first.to_primitives.to_s, "private-video.mp4"
        end

        def test_rejects_lifecycle_missing_id_and_oversized_identity_results
          lifecycle = official_result(id: "event-1", event_type: "SUBSCRIBED")
          missing_id = official_result(id: nil)
          oversized_sender = official_result(id: "message-2", sender: "s" * 256)

          assert_empty InboundMessage.parse_all("results" => [lifecycle, missing_id, oversized_sender])
        end

        def test_bounds_content_coordinates_and_batch_fanout
          results = 2005.times.map do |index|
            official_result(id: "message-#{index}", text: "x" * (InboundMessage::MAX_TEXT_BYTES + 20))
          end
          results.first["message"]["message"]["location"] = {
            "latitude" => 999,
            "longitude" => Float::INFINITY
          }

          messages = InboundMessage.parse_all("results" => results)

          assert_equal InboundMessage::MAX_BATCH_RESULTS, messages.size
          assert_equal InboundMessage::MAX_TEXT_BYTES, messages.first.text.bytesize
          refute messages.first.location?
          assert_equal "message-1999", messages.last.message_id
          assert_operator JSON.generate(messages.first.to_primitives).bytesize, :<, 5000
        end

        private

        def official_result(id:, sender: "opaque-viber-user", event_type: "MESSAGE", text: "Zdravo")
          {
            "sender" => sender,
            "to" => "configured-viber-bot",
            "integrationType" => "VIBER_BOTS",
            "messageId" => id,
            "message" => {
              "type" => event_type,
              "sender" => { "id" => sender },
              "message" => { "type" => "TEXT", "text" => text }
            }
          }
        end
      end
    end
  end
end
