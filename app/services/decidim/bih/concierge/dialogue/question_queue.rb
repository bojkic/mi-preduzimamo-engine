# frozen_string_literal: true

require_relative "text_predicates"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE CITIZEN'S OTHER QUESTIONS, from the message they asked them in.
        #
        # == The defect this closes
        #
        # `r5c09`, verbatim: *"Kad se odvozi smeće u Ulici Meše Selimovića i
        # kako da se registrujem i ko vodi u trci komšiluka?"* Three questions,
        # one message. Milica answered the third, and the citizen then asked
        # for the others by ordinal — *"A drugo pitanje?"*, *"A treće?"* — and
        # got the account menu and the rewards catalogue. Re-measured on the
        # live site 14.09.2026: *"Koliko bodova nosi prijava problema? A kada
        # je lansiranje?"* answers the first and then returns the top-level
        # four-option menu to *"A drugo pitanje?"*.
        #
        # == Why the previous owner's approach could not work, and this can
        #
        # Continuing from the last ANSWERED subject cannot recover an
        # UNANSWERED one, and in `r5c09` it answered the wrong one of the
        # three — which is why +TextPredicates.queued_question?+ declines these
        # outright today, and why that decline was right as long as the last
        # answered subject was the only thing remembered.
        #
        # The queue is not derived from the answer. It is the citizen's own
        # message, split into the questions they actually asked, kept in the
        # order they asked them. "Drugo pitanje" then means the second one THEY
        # asked, which is the only thing it has ever meant.
        #
        # == What it is allowed to be
        #
        # Their own words, never a paraphrase, never anything from a reply.
        # At most MAX_QUESTIONS of them, each bounded, each shaped like a
        # question, and none of them credential-bearing. Anything malformed is
        # DROPPED rather than raised, exactly as every other optional record in
        # the state store: a convenience must never be able to destroy the
        # conversation around it. It expires with the answer context's window
        # and never outlives the conversation state.
        #
        # == THE QUEUE AND THE STASH ARE TWO MECHANISMS, AND BOTH ARE LIVE
        #
        # They answer different questions and neither replaces the other:
        #
        #   * the QUEUE (here) owns the other questions asked in the SAME
        #     message — "Kad se odvozi smeće u X i kako da se registrujem i ko
        #     vodi u trci?". It is reachable by ordinal ("A drugo pitanje?")
        #     and, since the round-3 re-test, by the resume word.
        #   * the STASH (+suspended_task+, +ProcedureRunner#resume_suspended_task+)
        #     owns a question deferred ACROSS turns — the task that was put
        #     down when another one took over.
        #
        # The stash is tried first, because it holds work with slots in it; the
        # queue is the fallback, because it holds words the citizen typed and
        # nothing else. Live on 14.09.2026 the queue arrived and the stash
        # stopped being reached on these turns — a reviewed card answers before
        # the model and writes no task, so nothing was ever suspended — and
        # "nastavi" answered "Nemam sačuvano pitanje" to a citizen who had
        # asked three questions in one breath and had two of them unanswered.
        module QuestionQueue
          KEY = "question_queue_v1"
          FIELDS = %w(questions opened_at expires_at).freeze
          # How many of the queued questions the resume word has already handed
          # out. Optional, and absent on a record written before it existed: a
          # queue that survives a deploy keeps working and simply starts at
          # zero. An ordinal request does NOT move it — the citizen navigating
          # their own list by number is not consuming it.
          CURSOR = "served"
          # The same ten-minute window the retained answer context uses. A
          # citizen who comes back later is starting a new thought, not
          # resuming a list.
          TTL = 10 * 60
          # More than four is a paragraph, not a list of questions.
          MAX_QUESTIONS = 4
          MIN_LENGTH = 8
          MAX_LENGTH = 160
          # A whole message longer than this is prose; splitting it would
          # invent questions rather than find them.
          MAX_MESSAGE = 400

          # Sentence punctuation, exactly the split Coordinator#cancellation_question
          # and PersonalReadRoutes#clause already use.
          SENTENCE = /[.!?;\n]+/
          # The interrogative openers a second question actually starts with.
          # Every literal space is spelled [ ] — this is an /x pattern, and /x
          # drops unescaped spaces silently.
          OPENER = /(?:kako|gdje|gde|sta|sto|koji|koja|koje|koliko|kada|kad|zasto|cemu|ko|
                      da[ ]li|jel|jeli|dal|mogu[ ]li|imam[ ]li|jesam[ ]li|treba[ ]li|ima[ ]li|
                      how|where|what|which|when|why|who|can[ ]i|do[ ]i|is[ ]there)/x
          # "… i kako da se registrujem i ko vodi …" — a coordinating
          # conjunction that is IMMEDIATELY followed by an interrogative opener
          # is joining two questions. Anywhere else it is joining two nouns
          # ("smeće i kabasti otpad"), which is why the lookahead is required
          # and why nothing splits on a bare "i".
          CONJUNCTION = /\s+(?:i|a|te|and)\s+(?=#{OPENER.source}\b)/x
          # A part is kept only if it asks something: it opens with an
          # interrogative, optionally behind the continuation particle a
          # citizen writes a second question with ("A kada je lansiranje?").
          # Every literal space is spelled [ ]; /x drops a real one silently.
          QUESTION_SHAPE = /\A(?:(?:a|i|pa|te|and)[ ])?#{OPENER.source}\b/x

          module_function

          # The questions this message asks, in order, or nil when it does not
          # ask more than one. Their own words, unfolded: whatever is served
          # back is exactly what they typed.
          def split(text)
            return unless text.is_a?(String)

            trimmed = text.strip
            return if trimmed.empty? || trimmed.length > MAX_MESSAGE

            parts = sentences(trimmed).flat_map { |sentence| conjuncts(sentence) }
            questions = parts.select { |part| question?(part) }
            return unless questions.length.between?(2, MAX_QUESTIONS)

            questions
          end

          # A validated record, or nil when this turn has no queue to keep.
          # Never raises: a caller that cannot retain simply does not.
          def capture(text, now:, state_expires_at:)
            questions = split(text)
            return if questions.nil?

            opened = now.to_f
            normalize({ "questions" => questions, "opened_at" => opened,
                        "expires_at" => [opened + TTL, state_expires_at.to_f].min },
                      now:, state_expires_at:)
          end

          # Every rule below is a drop, never a raise. The state store runs
          # this on every read and every write.
          def normalize(value, now:, state_expires_at:)
            return nil unless value.is_a?(Hash)

            fields = value.transform_keys(&:to_s)
            return nil unless (fields.keys - [CURSOR]).sort == FIELDS.sort

            questions = valid_questions(fields.fetch("questions"))
            return nil if questions.nil?

            opened = Float(fields.fetch("opened_at"))
            expires = Float(fields.fetch("expires_at"))
            return nil unless live_window?(opened, expires, now:, state_expires_at:)

            record = { "questions" => questions, "opened_at" => opened, "expires_at" => expires }
            cursor = served(fields)
            cursor.zero? ? record : record.merge(CURSOR => [cursor, questions.length].min)
          rescue ArgumentError, TypeError, KeyError
            nil
          end

          # How many questions the resume word has served, bounded and never
          # negative. Anything malformed reads as none served, like every other
          # rule here.
          def served(value)
            cursor = value.is_a?(Hash) ? value[CURSOR] : nil
            return 0 unless cursor.is_a?(Integer) && cursor.positive?

            cursor
          end

          # The next question the resume word should hand out, or nil when the
          # list is exhausted. Never the ordinal reader's business: that one
          # indexes the list and leaves the cursor alone.
          def next_unserved(value)
            return unless value.is_a?(Hash)

            questions = value["questions"]
            return unless questions.is_a?(Array)

            questions[served(value)]
          end

          # The same record with the cursor advanced by one. Returns the record
          # unchanged once the list is exhausted, so a caller can advance
          # blindly.
          def advance(value)
            return value unless next_unserved(value)

            value.merge(CURSOR => served(value) + 1)
          end

          def valid_questions(questions)
            return nil unless questions.is_a?(Array) && questions.length.between?(2, MAX_QUESTIONS)
            return nil unless questions.all? { |question| valid_question?(question) }

            questions.map(&:to_s).freeze
          end

          # Opened in the past, not yet expired, never living longer than TTL
          # and never outliving the conversation state around it.
          def live_window?(opened, expires, now:, state_expires_at:)
            opened.finite? && expires.finite? && expires > now.to_f &&
              expires <= opened + TTL && expires <= state_expires_at.to_f
          end

          # The question the citizen means by "A drugo pitanje?", or nil. The
          # ordinal indexes THEIR list, one-based, because that is what the
          # word means; an ordinal past the end of the list recovers nothing
          # and the caller falls through rather than serving a different one.
          def question_at(value, ordinal)
            return unless value.is_a?(Hash) && ordinal.is_a?(Integer) && ordinal.positive?

            questions = value["questions"]
            return unless questions.is_a?(Array)

            questions[ordinal - 1]
          end

          def sentences(text)
            text.split(SENTENCE).map(&:strip).reject(&:empty?)
          end

          def conjuncts(sentence)
            sentence.split(CONJUNCTION).map(&:strip).reject(&:empty?)
          end

          def question?(part)
            return false unless valid_question?(part)

            QUESTION_SHAPE.match?(Decidim::Bih::Text.fold(part))
          end

          def valid_question?(part)
            part.is_a?(String) && part.length.between?(MIN_LENGTH, MAX_LENGTH) &&
              part.match?(/\p{L}/) && !TextPredicates.credential?(part)
          end
        end
      end
    end
  end
end
