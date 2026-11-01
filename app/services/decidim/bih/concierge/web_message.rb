# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      # Channel value object for ONE inbound message from the public WEB chat
      # widget (POST /chat). It exposes exactly the primitives the concierge
      # brain (Responder) reads — #text, #image_url, #latitude, #longitude — so
      # the same brain that serves Viber serves the website with no special
      # casing.
      #
      # The web widget still has no photo upload and never files reports directly
      # from chat. It can, however, attach a browser geolocation to a single turn
      # as TRANSIENT CONTEXT for questions like "odavde" / "ova lokacija". The
      # #location_context? flag lets the responder distinguish that from a Viber
      # LOCATION message, where coordinates are a real report signal.
      #
      # #sender is deliberately ABSENT (not nil-returning): the Responder guards
      # account linking behind `message.respond_to?(:sender)`, so omitting it
      # keeps the multi-turn phone-verification flow off for anonymous web
      # visitors. The controller may pass a bounded, short-lived transcript
      # summary so follow-up questions can be interpreted without exposing a
      # durable sender id to the brain.
      #
      # #user carries the LOGGED-IN Decidim::User (or nil for an anonymous
      # visitor). It is the ONLY identity the web channel exposes — there is no
      # phone linking on the web — and the host's goodwill_user_resolver reads it
      # to answer the personal "moji bodovi" intent. It is never used to file or
      # attribute reports (the web chat does not create reports in v1).
      class WebMessage
        attr_reader :text, :user, :conversation_context, :latitude, :longitude,
                    :location_accuracy, :location_purpose, :location_provenance, :location_acquired_at, :trusted_context

        # +text+ is the raw user message (already extracted from the JSON body
        # and scrubbed of leading/trailing whitespace by the controller).
        # +user+ is the authenticated Decidim::User, or nil when anonymous.
        # +location+ is a validated Hash with :latitude/:longitude for this turn,
        # or nil. +conversation_context+ is a bounded array of previous turn
        # summaries from the controller cache.
        def initialize(text, user: nil, location: nil, conversation_context: [], trusted_context: nil)
          @text = text.to_s
          @user = user
          @trusted_context = trusted_context
          @latitude = coordinate(location, :latitude, :lat)
          @longitude = coordinate(location, :longitude, :lon, :lng)
          @location_accuracy = coordinate(location, :accuracy)
          @location_accuracy_valid = location_value(location, :accuracy).nil? || (@location_accuracy&.between?(0, 1_000_000) == true)
          @location_purpose = location_value(location, :purpose)
          @location_provenance = location_value(location, :provenance)
          @location_acquired_at = browser_acquisition_time(location)
          @location_acquisition_invalid = @location_provenance == "browser_geolocation" &&
                                          !location_value(location, :acquired_at).nil? && @location_acquired_at.nil?
          @location_consent = location_value(location, :consent) == true
          @location_retention_consent = location_value(location, :retain_for_conversation) == true
          @conversation_context = Array(conversation_context)
        end

        def self.location_requested?(text)
          value = text.to_s.downcase
          return false if location_refused?(value)

          phrases = /odavde|ovdje|ovde|ovoj\ lokaciji|ovu\ lokaciju|ova\ lokacija|trenutna\ lokacija|trenutne\ lokacije|trenutnoj\ lokaciji|moja\ lokacija|moje\ lokacije|mojoj\ lokaciji|tu|from\ here|here|my\ location|
                     одавде|овдје|овде|овој\ локацији|ову\ локацију|ова\ локација|моја\ локација|моје\ локације|мојој\ локацији|тренутна\ локација|тренутне\ локације|тренутној\ локацији/ux
          value.match?(/(?:\A|[^\p{L}])(?:#{phrases})(?:\z|[^\p{L}])/u) ||
            value.match?(/(?:u kojoj sam|у којој сам|which.*am i).*(?:zon|зон)/u)
        end

        # A current request's structured consent may authorize location without
        # a language whitelist. Explicit textual refusal still takes precedence
        # over that metadata, including for older clients.
        def self.location_refused?(text)
          text.to_s.downcase.match?(/(?:\A|[^\p{L}])(?:bez|without|без|nemoj(?:te)?|немој(?:те)?|ne|не|do not|don't|dont)\s+[^.!?;\n]{0,60}(?:lokacij\p{L}*|локациј\p{L}*|location)(?:\z|[^\p{L}])/u)
        end

        def credential_handled?
          Dialogue::StateStore.sensitive_text?(text)
        end

        # Web chat carries no photo.
        def image_url
          nil
        end

        # True only for browser-provided contextual location; Viber messages do
        # not implement this and therefore keep existing report-signal behavior.
        def location_context?
          (latitude&.between?(-90, 90) && longitude&.between?(-180, 180)) || false
        end

        def location_consent?
          @location_consent
        end

        def location_retention_consent?
          @location_retention_consent && location_consent?
        end

        def public_read_location
          dialogue_location
        end

        def dialogue_location
          return unless location_context? && location_consent? && location_purpose == "current_location"
          return if @location_acquisition_invalid
          return unless @location_accuracy_valid && %w(browser_geolocation legacy_explicit_location external_explicit_location).include?(location_provenance)

          value = { latitude:, longitude:, accuracy: location_accuracy, purpose: location_purpose,
                    consent: true, provenance: location_provenance }
          value[:acquired_at] = location_acquired_at if location_acquired_at
          value.freeze
        end

        private

        # Browser GeolocationPosition.timestamp is milliseconds since epoch.
        # Bound it against the server's receipt clock; other channels do not
        # supply this browser-specific acquisition signal.
        def browser_acquisition_time(location)
          return unless location_provenance == "browser_geolocation"

          raw = location_value(location, :acquired_at)
          return if raw.nil? || raw.to_s.strip.empty?

          milliseconds = Float(raw)
          return unless milliseconds.finite?

          acquired = milliseconds / 1000.0
          receipt = trusted_context&.now&.to_f || Time.now.to_f
          acquired if acquired.between?(receipt - 600, receipt + 60)
        rescue ArgumentError, TypeError
          nil
        end

        def location_value(location, key)
          return unless location.respond_to?(:key?) && location.respond_to?(:[])

          location.has_key?(key) ? location[key] : location[key.to_s]
        end

        def coordinate(location, *keys)
          return nil unless location.respond_to?(:key?) && location.respond_to?(:[])

          value = keys.filter_map { |key| location[key] || location[key.to_s] }.first
          return nil if value.to_s.strip.blank?

          numeric = Float(value)
          numeric if numeric.finite?
        rescue ArgumentError, TypeError
          nil
        end
      end
    end
  end
end
