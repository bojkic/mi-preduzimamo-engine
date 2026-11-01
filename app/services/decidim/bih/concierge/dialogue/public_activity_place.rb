# frozen_string_literal: true

require_relative "public_activity_continuation"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A literal citizen query, never a resolved area identity. The owning
        # tenant matcher still decides whether this public place exists.
        module PublicActivityPlace
          ACTIVITY = /\b(?:
            sta[ ]se[ ](?:desava|dogadja)|dogadjaj\w*|aktivnost\w*|okupljan\w*|sastan\w*|volont\w*|projek\w*|
            events?|activities|meetings?|gatherings?|volunteer\w*|projects?
          )\b/x
          PLACE = /\b(?:u|na podrucju|in|within) (?<area>(?:mz|komsiluk(?:u)?|(?:mjesnoj|mesnoj) zajednici) .+)\z/
          NEGATION = /\b(?:ne u|nije u|osim u|not in|except in|nemoj)\b/
          TIMES = (PublicActivityContinuation::CALENDAR.keys + %w(uskoro soon vikend)).flat_map { |time| [time, "za #{time}"] }.sort_by { |time| -time.length }.freeze

          module_function

          def call(text:, supplied:)
            return unless text.is_a?(String) && text.length.between?(1, 160)

            folded = Text.fold(text)
            return unless public_activity_sentence?(folded)

            span = qualified_span(folded)
            return unless span
            return unless supplied.to_s.strip.empty? || Text.fold(supplied) == span.sub(/\A(?:mz|komsiluk) /, "")

            span
          end

          def public_activity_sentence?(folded)
            ACTIVITY.match?(folded) && !PublicActivityContinuation::PRIVATE_CONTEXT.match?(folded) && !NEGATION.match?(folded)
          end

          def qualified_span(folded)
            span = PLACE.match(folded)&.[](:area)
            return unless span

            suffix = TIMES.find { |time| span.end_with?(" #{time}") }
            span = span.delete_suffix(" #{suffix}") if suffix
            span = span.sub(/\Akomsiluku /, "komsiluk ").sub(/\A(?:mjesnoj|mesnoj) zajednici /, "mz ")
            return unless PublicActivityContinuation::QUALIFIED_AREA.match?(span) && !PublicActivityContinuation::EXTRA_CLAUSE.match?(span)

            span
          end
        end
      end
    end
  end
end
