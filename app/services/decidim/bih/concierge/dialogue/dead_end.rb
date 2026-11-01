# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # WHAT A REFUSAL OWES THE CITIZEN.
        #
        # "Za ovo nemam provjeren podatak" is an honest sentence and a useless
        # turn: in the 14.09.2026 re-test it was byte-identical across 49 turns,
        # linked the PDF that supposedly holds the answer, and offered nothing
        # to do next. Four of twenty-one conversations ended there.
        #
        # This module holds the ONE decision that repair needs, so that it is
        # stated once and testable once: does a missing slot explain the
        # refusal, or does the citizen need the responsible service?
        #
        #   unlocking_slot -> "area_query"  ask the one thing that unlocks the
        #                                   read. Proven, not assumed: the same
        #                                   waste question that refuses without
        #                                   a street answers with one.
        #   unlocking_slot -> nil           no question would help; the caller
        #                                   names the responsible destination.
        #
        # == What this module must never do
        #
        # It never changes what a refusal MEANS. Missing data, an unavailable
        # source, unreviewed evidence, an unauthorized read and a checked zero
        # result stay five different outcomes with five different labels; this
        # only decides which next step is attached to the two of them that
        # carried none. Asking a question is the single exception, and it is a
        # genuinely different ending (Resolution::CLARIFICATION, a pending slot
        # the citizen can fill) rather than a relabelled refusal.
        module DeadEnd
          # Topics whose reviewed record is selected BY PLACE, so that naming a
          # place is what turns "I hold no record" into a record.
          #
          # +waste+ is the evidence: its weekly schedule is keyed by street and
          # the procedure does not collect a place first (it is deliberately not
          # in ServiceQuestion::TOPICS), so every place-less waste question
          # reaches the reader and refuses. water/electricity/heating ARE asked
          # for a place first, so they reach this only through a directory or
          # announcement read — where the guard below declines anyway, because
          # the place is already supplied.
          PLACE_KEYED_TOPICS = %w(waste water electricity heating roads).freeze

          # The read's OWN account of why it came back with nothing, and the
          # only evidence that a place would have changed the answer. The host
          # types these; this is the subset that means "the source was searched
          # and the search key was not a place".
          #
          # Deliberately one code. A question answered from a reviewed contact
          # card — "Koji je telefon Vodovoda?", "Da li Komunalac radi subotom?"
          # — never needs a neighbourhood, and gating on the topic alone asked
          # every one of them for a street. Widening this list is how a second
          # reader opts in, and it is a behaviour change each time.
          PLACE_UNLOCKED_WARNINGS = %w(no_reviewed_matching_schedule).freeze

          module_function

          # +has_location+ is the turn's own predicate (an area/street/address
          # slot OR a shared browser location), passed in so this module stays
          # free of the turn. A place the citizen already gave is never asked
          # for twice: that is exactly the loop the re-test recorded, where
          # supplying "Dašnicu" returned the byte-identical refusal.
          def unlocking_slot(topic:, warnings:, has_location:, pending_slot: nil)
            return nil unless PLACE_KEYED_TOPICS.include?(topic)
            return nil unless Array(warnings).intersect?(PLACE_UNLOCKED_WARNINGS)
            return nil if has_location
            # We already asked for this and the answer did not become a place.
            # Asking again is the loop, not the repair.
            return nil if pending_slot == "area_query"

            "area_query"
          end
        end
      end
    end
  end
end
