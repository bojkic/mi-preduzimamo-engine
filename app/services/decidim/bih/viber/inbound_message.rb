# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # Bounded value object for one inbound Viber Bot message. Infobip's
      # current Viber Bots callback wraps the actual TEXT/IMAGE/LOCATION value
      # inside a MESSAGE event. The earlier flattened result shape remains
      # accepted so existing hosts and captured fixtures stay compatible.
      class InboundMessage
        MAX_IDENTIFIER_BYTES = 255
        MAX_MESSAGE_ID_BYTES = 255
        MAX_TEXT_BYTES = 4096
        MAX_MEDIA_URL_BYTES = 2048
        MAX_TYPE_BYTES = 64
        MAX_CONTENT_ITEMS = 100
        MAX_BATCH_RESULTS = 2000
        CHANNEL = "viber"
        INTEGRATION_TYPES = %w(viber_bot viber_bots).freeze
        NON_MESSAGE_EVENT_TYPES = %w(delivered subscribed unsubscribed conversation_started).freeze
        VERIFY_CONTEXT_PATTERN = /\Averify_[A-Za-z0-9_-]{20,128}\z/

        attr_reader :channel, :sender, :recipient, :text, :image_url,
                    :latitude, :longitude, :type, :message_id, :raw

        class << self
          # Builds a message even when optional/required provider fields are
          # absent. Callers that persist receipts should use #parse_all, which
          # filters malformed and non-message events through #receipt_safe?.
          def parse(payload_hash)
            new(extract_result(payload_hash))
          end

          def parse_all(payload_hash)
            return [] unless payload_hash.respond_to?(:[])

            results = fetch_any(payload_hash, "results")
            results = [payload_hash] unless results.is_a?(Array)

            results.first(MAX_BATCH_RESULTS).filter_map do |result|
              next unless supported_result?(result)

              message = new(result)
              message if message.receipt_safe?
            rescue StandardError
              nil
            end
          rescue StandardError
            []
          end

          def from_primitives(attributes)
            attributes = attributes.to_h
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
              "integrationType" => "VIBER_BOTS",
              "sender" => fetch_any(attributes, "sender"),
              "to" => fetch_any(attributes, "recipient"),
              "messageId" => fetch_any(attributes, "message_id"),
              "message" => message
            )
          end

          def extract_result(payload)
            return {} unless payload.respond_to?(:[])

            results = fetch_any(payload, "results")
            return results.first || {} if results.is_a?(Array)

            payload
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

          def supported_result?(result)
            return false unless result.respond_to?(:[])
            return false unless inbound_message_event?(result)

            declared = fetch_any(result, "integrationType", "integration_type", "channel")
            return false unless integration_type_supported?(declared)

            wrapper = fetch_any(result, "message")
            wrapper_type = fetch_any(wrapper, "type").to_s.strip.downcase
            return !verification_context(wrapper).nil? if wrapper_type == "conversation_started"

            NON_MESSAGE_EVENT_TYPES.none? { |type| type == wrapper_type }
          end

          # Viber Bots deliver a deep-link context in a CONVERSATION_STARTED
          # event, not as an ordinary TEXT message. Admit only the narrowly
          # namespaced single-use verification token; all other lifecycle
          # contexts remain filtered and can never enter the concierge.
          def verification_context(wrapper)
            context = fetch_any(wrapper, "context").to_s
            context if context.bytesize <= MAX_TEXT_BYTES && context.match?(VERIFY_CONTEXT_PATTERN)
          end

          def inbound_message_event?(result)
            event = fetch_any(result, "event")
            event.nil? || event.to_s.strip.empty? || event.to_s.casecmp?("MO")
          end

          def integration_type_supported?(declared)
            return true if declared.nil? || declared.to_s.strip.empty?

            INTEGRATION_TYPES.include?(normalize_integration_type(declared))
          end

          def normalize_integration_type(value)
            value.to_s.strip.downcase.tr(" -", "__")
          end
        end

        def initialize(result)
          @raw = result.respond_to?(:[]) ? result : {}
          wrapper = fetch_any(@raw, "message") || {}
          message = normalized_content(wrapper)
          wrapper_sender = fetch_any(wrapper, "sender", "user") || {}

          @channel = CHANNEL
          @sender, invalid_sender = bounded_identifier(
            fetch_any(wrapper_sender, "id") || fetch_any(@raw, "from", "sender"),
            MAX_IDENTIFIER_BYTES
          )
          @recipient, invalid_recipient = bounded_identifier(
            fetch_any(@raw, "to", "recipient", "destination"),
            MAX_IDENTIFIER_BYTES
          )
          @message_id, invalid_message_id = bounded_identifier(
            fetch_any(@raw, "messageId", "message_id", "messageToken", "message_token") ||
              fetch_any(wrapper, "messageId", "message_id", "messageToken", "message_token") ||
              fetch_any(message, "messageId", "message_id", "messageToken", "message_token", "id"),
            MAX_MESSAGE_ID_BYTES
          )
          @invalid_identity = invalid_sender || invalid_recipient || invalid_message_id
          @type = bounded_text(fetch_any(message, "type"), MAX_TYPE_BYTES)
          @text = bounded_text(fetch_any(message, "text", "caption", "description", "title"), MAX_TEXT_BYTES)
          @image_url = image_media_url(message)
          @latitude = coordinate(message, :latitude)
          @longitude = coordinate(message, :longitude)
        end

        def receipt_safe?
          !@invalid_identity && !sender.nil? && !message_id.nil?
        end

        def location?
          !latitude.nil? && !longitude.nil?
        end

        def to_primitives
          {
            "channel" => channel,
            "sender" => sender,
            "recipient" => recipient,
            "message_id" => message_id,
            "type" => type,
            "text" => text,
            "image_url" => image_url,
            "latitude" => latitude,
            "longitude" => longitude
          }.compact
        end

        private

        def fetch_any(hash, *keys)
          self.class.fetch_any(hash, *keys)
        end

        def actual_message(wrapper)
          return {} unless wrapper.respond_to?(:[])

          nested = fetch_any(wrapper, "message")
          return nested if fetch_any(wrapper, "type").to_s.casecmp?("MESSAGE") && nested.respond_to?(:[])

          wrapper
        end

        def normalized_content(wrapper)
          verification_context = self.class.send(:verification_context, wrapper)
          return { "type" => "TEXT", "text" => verification_context } if verification_context

          return actual_message(wrapper) if wrapper.respond_to?(:keys) && wrapper.keys.any?

          content = fetch_any(@raw, "content")
          consolidate_content(content)
        end

        def consolidate_content(content)
          items = content_items(content)
          return {} if items.empty?

          text = items.lazy.map do |item|
            presence(fetch_any(item, "text", "caption", "description", "title"))
          end.find(&:itself)
          media_url = items.lazy.map do |item|
            image_media_url(item)
          end.find(&:itself)
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
          latitude = coordinate(item, :latitude)
          longitude = coordinate(item, :longitude)
          return unless latitude && longitude

          { "latitude" => latitude, "longitude" => longitude }
        end

        def coordinate(message, axis)
          keys = axis == :latitude ? %w(latitude lat) : %w(longitude lng lon)
          container = fetch_any(message, "location", "coordinates")
          value = fetch_any(container, *keys) if container.respond_to?(:[])
          value = fetch_any(message, *keys) if value.nil?
          number = Float(value)
          return unless number.finite?
          return unless axis == :latitude ? (-90..90).cover?(number) : (-180..180).cover?(number)

          number
        rescue ArgumentError, TypeError
          nil
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
      end
    end
  end
end
