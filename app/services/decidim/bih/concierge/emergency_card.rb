# frozen_string_literal: true

require_relative "../text"
require_relative "emergency_signal"

module Decidim
  module Bih
    module Concierge
      # Composes the reply to an immediate-danger turn: the RELEVANT service
      # first, in the script the citizen wrote in.
      #
      # == Why this exists
      #
      # Every emergency answer used to be one string — police 122 and the
      # domestic-violence SOS line first, whatever had happened. A citizen
      # standing in front of a burning container, or beside someone who is not
      # breathing, had to read past two irrelevant numbers to find theirs. The
      # card now leads with the service for the danger that was recognised.
      #
      # == What it will not do
      #
      # * It never invents a number. Every contact here is already published to
      #   citizens in reviewed copy (the four numbers in +dialogue.safety+);
      #   selecting between them is code, the contacts themselves are copy, and
      #   a new contact is a copy change with a reviewer, not a code change.
      # * It never claims that help has been called, dispatched or is on its
      #   way, and it never promises a response time — the disclaimer line says
      #   plainly that Milica does not call anyone and does not track the call.
      # * It never gives medical, firefighting or evacuation instructions. The
      #   only instruction is which number to ring.
      module EmergencyCard
        LOCALES = %w(sr sr-Cyrl bs hr en).freeze
        DEFAULT_LOCALE = "sr"
        # Danger kind -> the line that names its service. A hazard (fire, gas,
        # water, a person who cannot get out) leads with the fire brigade,
        # because they are who comes out to it; a casualty leads with the
        # ambulance.
        KIND_KEYS = {
          "fire" => "emergency_fire", "gas" => "emergency_gas", "flood" => "emergency_flood",
          "trapped" => "emergency_trapped", "medical" => "emergency_medical"
        }.freeze
        SERVICE_KEYS = {
          "fire" => "emergency_service_fire", "medical" => "emergency_service_medical",
          "police" => "emergency_service_police"
        }.freeze
        # A second line is added only when the message carries a second need.
        ALSO_MEDICAL = "emergency_also_medical"
        ALSO_FIRE = "emergency_also_fire"
        DISCLAIMER = "emergency_disclaimer"
        GENERIC = "safety"
        # Enough English to tell an English message from a Serbian one without
        # a language model. Two hits and no Serbian word is the threshold; one
        # stray "the" in a Serbian sentence must not switch the whole card.
        ENGLISH_MARKERS = /\b(?:the|is|are|am|there|call|what|who|whom|number|now|help|please|
                             my|our|someone|somebody|people|children|inside|fire|smoke|gas|water|
                             trapped|burning|unconscious|breathing|ambulance|police|brigade|emergency)\b/x
        SERBIAN_MARKERS = /\b(?:je|su|mi|se|na|za|sam|ima|nema|odmah|zovi|zovem|broj|kuci|kuca|kucu|
                             gori|pozar|vatra|voda|dim|plin|gas[au]|hitn\w*|policij\w*|vatrogas\w*|
                             molim|hvala|sta|gdje|gde|koji|koga|djeca|deca|ljudi|komsij\w*)\b/x

        module_function

        # The card for a typed assessment. +people_present+ adds the ambulance
        # line for a follow-up that says someone is standing next to it.
        def call(assessment, locale:, people_present: false)
          return nil unless assessment.respond_to?(:kind) && KIND_KEYS.has_key?(assessment.kind)

          lead = translate(KIND_KEYS.fetch(assessment.kind), locale:)
          # An empty card is worse than no card: decline and let the caller's
          # own red-zone reply answer instead of sending a blank message.
          return nil if lead.to_s.strip.empty?

          second = second_line(assessment, people_present:)
          [lead, (translate(second, locale:) if second), translate(DISCLAIMER, locale:)].compact.join("\n")
        end

        # The answer to "koji je broj vatrogasaca?" — one reviewed contact and
        # the same disclaimer, with no incident inferred from the question.
        def for_service(service, locale:)
          key = SERVICE_KEYS[service.to_s]
          return nil unless key

          lead = translate(key, locale:)
          return nil if lead.to_s.strip.empty?

          [lead, translate(DISCLAIMER, locale:)].compact.join("\n")
        end

        # The unchanged all-services card, for danger this module did not type
        # (a threat, an assault, domestic violence): there the police and the
        # SOS line ARE the relevant services.
        def generic(locale:)
          translate(GENERIC, locale:)
        end

        # THE shared selection every channel makes: "is the danger in this text
        # one I can type, and if so what is its card?". nil means "not typed" —
        # the caller keeps whatever untyped danger answer it already has, which
        # is deliberately NOT the same string on every channel (the dialogue
        # coordinator has +generic+; the legacy brain has its own red-zone
        # copy with the do-not-post-personal-data line).
        #
        # Extracted because four call sites made this same choice by hand:
        # EmergencyStage, the host report conversation, Responder#safety_reply
        # and Coordinator.control_reply. The first two need the surrounding
        # flow (people_present, draft destruction) and keep their own wrapper;
        # the last two are exactly this and nothing else.
        def typed(text, fallback_locale: nil)
          assessment = EmergencySignal.assess(text)
          return nil unless assessment

          call(assessment, locale: locale_for(text, fallback: fallback_locale))
        end

        # The script the citizen is writing in, which the emergency card must
        # match: a Cyrillic question was being answered in Latin. Falls back to
        # the conversation's own locale, then to the request's, then to Serbian.
        def locale_for(text, fallback: nil)
          value = text.to_s
          return "sr-Cyrl" if value.match?(/\p{Cyrillic}/)
          return "en" if english?(Text.fold(value))

          [fallback, current_locale].compact.map(&:to_s).find { |locale| LOCALES.include?(locale) } || DEFAULT_LOCALE
        end

        def english?(folded)
          return false if folded.empty? || SERBIAN_MARKERS.match?(folded)

          folded.scan(ENGLISH_MARKERS).length >= 2
        end

        def second_line(assessment, people_present:)
          also = assessment.respond_to?(:also) ? assessment.also : nil
          return ALSO_MEDICAL if also == "medical" || (people_present && assessment.kind != "medical")
          return ALSO_FIRE if assessment.kind == "medical" && (also || people_present)

          nil
        end

        def translate(key, locale:)
          I18n.t("decidim.bih.dialogue.#{key}", locale: LOCALES.include?(locale.to_s) ? locale : DEFAULT_LOCALE, raise: true)
        rescue StandardError
          # A missing translation must never cost the citizen the card: the
          # Serbian line is the one that is always present. The second lookup
          # is itself guarded — an I18n backend that refuses even the default
          # locale (I18n::InvalidLocale, an unloaded backend) must leave the
          # caller with nil to fall back on, never with an exception raised out
          # of an emergency reply.
          begin
            I18n.t("decidim.bih.dialogue.#{key}", locale: DEFAULT_LOCALE, default: nil)
          rescue StandardError
            nil
          end
        end

        def current_locale
          defined?(I18n) ? I18n.locale : nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
