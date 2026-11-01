# frozen_string_literal: true

require "time"

module Decidim
  module Bih
    module Infobip
      # Channel-neutral value object for one inbound message delivered by
      # Infobip. The route owns the expected channel; a payload that declares a
      # different integrationType/channel is ignored so one public endpoint
      # cannot be used to inject a reply into another configured channel.
      #
      # Infobip normally wraps one or more results in `results`, but sandbox
      # captures and test tools sometimes post one result directly. Parsing is
      # deliberately lenient about both shapes, string/symbol keys and common
      # media/location field aliases. It accepts both channel-native messages
      # (`message` / `to`) and Messages API v2 messages
      # (`content[]` / `destination`). Missing optional values become nil.
      class InboundMessage
        MAX_IDENTIFIER_BYTES = 255
        MAX_MESSAGE_ID_BYTES = 255
        MAX_TEXT_BYTES = 4096
        MAX_MEDIA_URL_BYTES = 2048
        MAX_TYPE_BYTES = 64
        MAX_CONTENT_ITEMS = 100
        # Matches Infobip's maximum subscription bucket size. Anything beyond
        # this bound is ignored to prevent unbounded receipt/job fan-out.
        MAX_BATCH_RESULTS = 2000
        CHANNELS = %w(viber_bm whatsapp messenger instagram).freeze
        # "viber" maps to Business Messages here because this parser only ever
        # serves the Infobip chat routes. The Viber Bot has its own endpoint and
        # its own parser (Decidim::Bih::Viber::InboundMessage), so the two can
        # never be confused. Route channel is always supplied by the route, not
        # by request JSON.
        CHANNEL_ALIASES = {
          "viber" => "viber_bm",
          "viber_bm" => "viber_bm",
          "viber_business" => "viber_bm",
          "viber_business_messages" => "viber_bm",
          "whatsapp" => "whatsapp",
          "messenger" => "messenger",
          "facebook" => "messenger",
          "facebook_messenger" => "messenger",
          "instagram" => "instagram",
          "instagram_dm" => "instagram",
          "instagram_direct" => "instagram"
        }.freeze

        attr_reader :channel, :sender, :recipient, :text, :image_url,
                    :latitude, :longitude, :type, :message_id, :raw, :occurred_at

        class << self
          def parse(payload_hash, route_channel:)
            parse_all(payload_hash, route_channel:).first
          end

          def parse_all(payload_hash, route_channel:)
            expected_channel = normalize_channel(route_channel)
            return [] unless expected_channel && payload_hash.respond_to?(:[])

            results = fetch_any(payload_hash, "results")
            results = [payload_hash] unless results.is_a?(Array)

            results.first(MAX_BATCH_RESULTS).filter_map { |result| parse_result(result, expected_channel) }
          rescue StandardError
            []
          end

          def from_primitives(attributes)
            attributes = attributes.to_h
            channel = fetch_any(attributes, "channel")
            message = {
              "type" => fetch_any(attributes, "type"),
              "text" => fetch_any(attributes, "text"),
              "url" => fetch_any(attributes, "image_url")
            }
            latitude = fetch_any(attributes, "latitude")
            longitude = fetch_any(attributes, "longitude")
            if latitude || longitude
              message["location"] = {
                "latitude" => latitude,
                "longitude" => longitude
              }
            end

            new(
              {
                "integrationType" => channel,
                "from" => fetch_any(attributes, "sender"),
                "to" => fetch_any(attributes, "recipient"),
                "messageId" => fetch_any(attributes, "message_id"),
                "receivedAt" => fetch_any(attributes, "occurred_at"),
                "message" => message
              },
              route_channel: channel
            )
          end

          def normalize_channel(value)
            key = value.to_s.strip.downcase.tr(" -", "__")
            CHANNEL_ALIASES[key]
          end

          def fetch_any(hash, *keys)
            return nil unless hash.respond_to?(:[])

            keys.each do |key|
              [key, key.to_s, key.to_sym].uniq.each do |variant|
                value = hash[variant]
                return value unless value.nil?
              end
            end
            nil
          end

          private

          def parse_result(result, expected_channel)
            return unless result.respond_to?(:[])
            return unless route_matches?(result, expected_channel)
            return unless inbound_message_event?(result)

            message = new(result, route_channel: expected_channel)
            message if message.receipt_safe?
          rescue StandardError
            nil
          end

          def route_matches?(result, expected_channel)
            declared = fetch_any(result, "integrationType", "integration_type", "channel")
            return true if declared.nil? || declared.to_s.strip.empty?

            normalize_channel(declared) == expected_channel
          end

          # Messages API v2 includes an event discriminator. Only MO is a
          # citizen message; typing/seen/delivery events must never consume a
          # receipt or trigger an automated reply. Channel-native payloads do
          # not include this field and remain supported.
          def inbound_message_event?(result)
            event = fetch_any(result, "event")
            event.nil? || event.to_s.strip.empty? || event.to_s.casecmp?("MO")
          end
        end

        def initialize(result, route_channel:)
          @raw = result.respond_to?(:[]) ? result : {}
          @channel = self.class.normalize_channel(route_channel) ||
                     self.class.normalize_channel(fetch_any(@raw, "integrationType", "integration_type", "channel"))
          message = normalized_content(@raw)
          contact = fetch_any(@raw, "contact") || {}

          @sender, invalid_sender = bounded_identifier(
            fetch_any(contact, "userId", "user_id") || fetch_any(@raw, "from", "sender"),
            MAX_IDENTIFIER_BYTES
          )
          @recipient, invalid_recipient = bounded_identifier(
            fetch_any(@raw, "to", "recipient", "destination"),
            MAX_IDENTIFIER_BYTES
          )
          @message_id, invalid_message_id = bounded_identifier(
            fetch_any(@raw, "messageId", "message_id", "messageToken", "message_token") ||
            fetch_any(message, "messageId", "message_id", "messageToken", "message_token", "mid"),
            MAX_MESSAGE_ID_BYTES
          )
          @occurred_at = event_time(fetch_any(@raw, "receivedAt", "timestamp", "received_at"))
          @invalid_identity = invalid_sender || invalid_recipient || invalid_message_id
          @type = bounded_text(fetch_any(message, "type"), MAX_TYPE_BYTES)
          @text = bounded_text(fetch_any(message, "text", "caption", "description", "title"), MAX_TEXT_BYTES)
          @image_url = image_media_url(message)
          @latitude = coordinate(location_value(message, "latitude", "lat"), -90..90)
          @longitude = coordinate(location_value(message, "longitude", "lng", "lon"), -180..180)
        end

        def location?
          !latitude.nil? && !longitude.nil?
        end

        # Durable processing requires an idempotency key and a reply address.
        # Oversized identifiers are rejected, never truncated into collisions.
        def receipt_safe?
          !@invalid_identity && channel && sender && message_id
        end

        def to_primitives
          {
            "channel" => channel,
            "sender" => sender,
            "recipient" => recipient,
            "message_id" => message_id,
            "occurred_at" => occurred_at&.iso8601(6),
            "type" => type,
            "text" => text,
            "image_url" => image_url,
            "latitude" => latitude,
            "longitude" => longitude
          }.compact
        end

        private

        # Invalid or future provider timestamps never open a fresh session.
        def event_time(value)
          return unless value.is_a?(String) && value.bytesize <= 64

          parsed = Time.iso8601(value)
          parsed if parsed <= Time.now.utc && parsed.year >= 2000
        rescue ArgumentError
          nil
        end

        def fetch_any(hash, *keys)
          self.class.fetch_any(hash, *keys)
        end

        def normalized_content(result)
          native = fetch_any(result, "message")
          return native if native.respond_to?(:[])

          content = fetch_any(result, "content")
          return consolidate_content(content) unless content.nil?

          # Infobip's Instagram push configuration can put text directly on
          # the result. Keep the original text; cleanText may strip a keyword.
          return {} unless @channel == "instagram"

          { "type" => "TEXT", "text" => fetch_any(result, "text") }
        end

        # One provider messageId remains one durable receipt even when v2
        # delivers multiple content components. Select only the first bounded
        # value of each primitive the concierge can process; never manufacture
        # per-component ids that would weaken webhook redelivery idempotency.
        def consolidate_content(content)
          items = content_items(content)
          return {} if items.empty?

          text = items.lazy.map do |item|
            presence(fetch_any(item, "text", "caption", "description", "title"))
          end.find(&:itself)
          media_url = items.lazy.map { |item| image_media_url(item) }.find(&:itself)
          location = items.lazy.map { |item| complete_location(item) }.find(&:itself)

          {
            "type" => media_url ? "IMAGE" : fetch_any(items.first, "type"),
            "text" => text,
            "url" => media_url,
            "location" => location
          }.compact
        end

        def content_items(content)
          return [] unless content.is_a?(Array)

          content.first(MAX_CONTENT_ITEMS).filter_map do |item|
            next unless item.respond_to?(:[])

            body = fetch_any(item, "body")
            body.respond_to?(:[]) ? body : item
          end
        end

        def complete_location(item)
          latitude = coordinate(location_value(item, "latitude", "lat"), -90..90)
          longitude = coordinate(location_value(item, "longitude", "lng", "lon"), -180..180)
          return unless latitude && longitude

          { "latitude" => latitude, "longitude" => longitude }
        end

        def location_value(message, *keys)
          container = fetch_any(message, "location", "coordinates")
          if container.respond_to?(:[])
            nested = fetch_any(container, *keys)
            return nested unless nested.nil?
          end
          fetch_any(message, *keys)
        end

        def presence(value)
          return nil if value.nil?

          string = value.to_s
          string.strip.empty? ? nil : value
        end

        def bounded_identifier(value, max_bytes)
          value = presence(value)
          return [nil, false] if value.nil?

          string = value.to_s
          return [nil, true] if string.bytesize > max_bytes

          [string, false]
        end

        def bounded_text(value, max_bytes)
          value = presence(value)
          return if value.nil?

          string = value.to_s
          return string if string.bytesize <= max_bytes

          string.byteslice(0, max_bytes).to_s.scrub("")
        end

        def bounded_media_url(value)
          value = presence(value)
          return if value.nil?

          string = value.to_s
          string if string.bytesize <= MAX_MEDIA_URL_BYTES
        end

        def image_media_url(message)
          return unless fetch_any(message, "type").to_s.casecmp?("IMAGE")

          bounded_media_url(fetch_any(message, "url", "imageUrl", "image_url", "mediaUrl", "media_url"))
        end

        def coordinate(value, range)
          return nil if value.nil? || value.to_s.strip.empty?

          number = Float(value)
          return unless number.finite? && range.cover?(number)

          number
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
