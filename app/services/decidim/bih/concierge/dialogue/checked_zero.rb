# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # WHEN A READ HAS ALREADY ANSWERED, NEGATIVELY.
        #
        # In the 14.09.2026 648-turn replay one reply said both of these, four
        # lines apart:
        #
        #   "Za ovo nemam provjeren podatak."                  -> UNSUPPORTED
        #   "U pregledanoj objavi izvora nema nijednog
        #    obavještenja za traženo područje i period."       -> a scoped zero
        #                                                         result, which
        #                                                         is ANSWERED
        #
        # Those are different claims about the world — "I hold no record" and
        # "I read the record and it is empty for you" — and the citizen could
        # not tell which was true. This module holds the ONE decision that
        # separates them: does the read's own account already state a checked
        # zero result?
        #
        # The evidence is the reader's warning codes, not the topic and not the
        # status. Both codes below are emitted by the host ReadPort only after
        # the source was actually reached, and both are documented there as a
        # scoped zero result rather than a pending review or an outage.
        #
        # == What this module must never do
        #
        # It never makes a refusal sound better. A read that reached nothing,
        # a stale source, unreviewed evidence and an unauthorized read all stay
        # exactly where they were, with their own labels and their own next
        # step. This only recognises the one case where the refusal sentence
        # was the false one — the source WAS read — and hands the turn its own
        # sentence instead of two contradictory ones.
        module CheckedZero
          # Codes whose meaning is "the source was reached and holds nothing
          # for the area and period asked about".
          #
          #   no_matching_source_notice      the reviewed publication is empty
          #   source_scope_or_time_not_matched
          #                                  the publication was read and its
          #                                  collected notices do not cover the
          #                                  asked scope
          #
          # Deliberately two codes. Widening this list moves turns from
          # UNSUPPORTED to ANSWERED, which is an accounting change as well as a
          # copy change, so it is a behaviour decision every time.
          CLAIMS = %w(no_matching_source_notice source_scope_or_time_not_matched).freeze

          module_function

          # The first checked-zero code this read carries, in the reader's own
          # priority order (the host ReadPort already sorts its warnings), or
          # nil when the read makes no such claim.
          def claim(warnings)
            Array(warnings).find { |code| CLAIMS.include?(code) }
          end
        end
      end
    end
  end
end
