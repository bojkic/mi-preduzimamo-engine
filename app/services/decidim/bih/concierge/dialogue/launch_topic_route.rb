# frozen_string_literal: true

require_relative "public_information"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The belt to PublicInformationStage's braces: any remaining
        # launch/invitation utterance is PINNED to the launch topic so the
        # understanding call can never offer it to the public-calls reader.
        #
        # Why a pin and not a refusal: the city-service keyword matchers compare
        # by SUBSTRING, and "pozivnicu" contains "poziv". A citizen asking when
        # their invitation expires was answered with a Grad Bijeljina SME call
        # closing 17.09.2026 — a genuine, sourced, plausible date, one day after
        # the real 16.09. cutoff and on the event date itself. Selecting the
        # launch read deterministically removes the model's opportunity to make
        # that substitution at all.
        #
        # == Where it sits in the order
        #
        # Last. Every built-in route keeps its position, and in particular the
        # own-state "invitation" route still wins for "imam li pozivnicu" and
        # "kada je lansiranje" — those are reads of the citizen's own row, not
        # campaign policy.
        #
        # An explicit public-call term (javni poziv, konkurs, natječaj,
        # stipendija, subvencija, grant, MSP) means the citizen really did ask
        # about a konkurs, and this route declines so the public-calls reader
        # keeps it.
        module LaunchTopicRoute
          # Deliberately narrower than PublicInformation::LAUNCH_ANCHOR: bare
          # date literals ("17. septembra") and venue names appear naturally in
          # messages about something else entirely, which is the same reason
          # Responder::LAUNCH_KEYWORDS excludes them.
          ANCHOR = /(?:pozivnic|lansiranj|trk[aeiou]\s+komsiluka)/

          module_function

          def read(query, text)
            return unless ANCHOR.match?(query)
            return if PublicInformation::PUBLIC_CALL_TERM.match?(query)

            { action: "ask_information", topic: "launch", entities: { "query" => text } }
          end
        end

        DeterministicRoutes.register("launch_topic") do |query, text|
          LaunchTopicRoute.read(query, text)
        end
      end
    end
  end
end
