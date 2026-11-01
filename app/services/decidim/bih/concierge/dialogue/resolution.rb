# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE resolution vocabulary and the state effects +finish(resolution:)+
        # applies. A resolution is how a turn ended; it drives the aggregate
        # counters, the operator's answer-quality review and whether the turn
        # still owes the citizen something.
        #
        # == The one place a label is decided
        #
        # Procedures pass their resolution to +ProcedureRunner::Turn#finish+,
        # which asks this module what that label means for the task state. The
        # predicates below are the whole rule set, in the order finish applies
        # them:
        #
        #   1. settles_task?         — a clarification keeps the pending slot
        #                              and the clarification count; anything
        #                              else settles the task (unless the caller
        #                              passed preserve_task:).
        #   2. retains_pending_slot? — a hand-off offered at the clarification
        #                              limit keeps the slot it was asking for.
        #   3. retains_clarification_count? — the same hand-off keeps the count.
        #   4. offers_resume?        — a suspended task is offered back once,
        #                              on any turn that is not a clarification.
        #
        # == The honest-outcome rule (Task 9b)
        #
        # "Answered" means the citizen's question was answered. It does NOT
        # mean a reply was produced — every branch produces a reply. Two
        # branches used to end with +answered+ while telling the citizen
        # "Za ovo nemam provjeren podatak" ("I have no verified data for
        # this"), so every one of those refusals was counted as a success in
        # ConciergeUsageAggregate and in the operator's answer-quality review.
        # +empty_read+ and +empty_available_read+ are the two labelling
        # DECISIONS that live here rather than at their call sites, so that the
        # rule is stated once and testable once.
        #
        # The distinction they preserve is the one that matters:
        #
        #   "I checked the volunteer catalogue for these komsiluci over this
        #    window and there are none"   -> a real, scoped, complete
        #                                    zero-result ANSWER
        #   "I have no verified data"     -> we could not find out; UNRESOLVED
        #
        # A zero-result answer is still an answer and must never be recorded
        # as a failure. A refusal is not an answer and must never be recorded
        # as a success.
        #
        # == Three things that are NOT the same, and never share a label
        #
        #   source/provider health  SOURCE_UNAVAILABLE, PROVIDER_UNAVAILABLE
        #                           - the source or the model could not be
        #                             used. Says nothing about the question.
        #   task resolution         everything in VALUES - how the TURN ended.
        #   human rating            helpful / not_helpful, recorded by the
        #                           citizen. Never derived from a resolution
        #                           and never written here.
        #
        # Safety guidance is a fourth thing again: it tells the citizen which
        # emergency number to call. It is never a dispatch and never an
        # incident resolution - Milica contacted nobody and resolved nothing -
        # so it must never be labelled ANSWERED, SUBMITTED or DELIVERY_FAILED.
        # It carries SAFETY_GUIDANCE, an unresolved incident with useful contact
        # guidance. Its dedicated counter must be reported separately from
        # unsupported requests and from voluntary citizen ratings.
        module Resolution
          ANSWERED = "answered"
          CLARIFICATION = "clarification"
          HANDOFF = "handoff"
          DRAFT = "draft"
          SUBMITTED = "submitted"
          CANCELLED = "cancelled"
          UNSUPPORTED = "unsupported"
          SOURCE_UNAVAILABLE = "source_unavailable"
          DELIVERY_FAILED = "delivery_failed"
          PROVIDER_UNAVAILABLE = "provider_unavailable"
          BUSY = "busy"
          SAFETY_GUIDANCE = "safety_guidance"

          # The full vocabulary, in the order UsageAggregateRecorder::RESOLUTIONS
          # lists it. The recorder owns persistence (which of these have a daily
          # counter column); this is the dialogue-side name list, and the two
          # must agree — a contract test asserts it.
          VALUES = [
            ANSWERED, CLARIFICATION, HANDOFF, DRAFT, SUBMITTED, CANCELLED, UNSUPPORTED,
            SOURCE_UNAVAILABLE, DELIVERY_FAILED, PROVIDER_UNAVAILABLE, BUSY, SAFETY_GUIDANCE
          ].freeze

          # Resolutions that mean the citizen still owes or is owed a step.
          OPEN = [CLARIFICATION, HANDOFF].freeze

          # The source or the model could not be used. A machine-health
          # statement about a dependency, never a statement about the answer
          # and never a citizen rating.
          SOURCE_HEALTH = [SOURCE_UNAVAILABLE, PROVIDER_UNAVAILABLE].freeze

          # The requested task or incident remains unresolved. Safety contact
          # guidance has its own label and is not an unsupported request.
          # Other labels mean no answer or task advancement was possible.
          # A reply was still produced and the citizen was told so honestly.
          UNRESOLVED = [UNSUPPORTED, SOURCE_UNAVAILABLE, DELIVERY_FAILED, PROVIDER_UNAVAILABLE, BUSY, SAFETY_GUIDANCE].freeze

          # THE historical aggregate bucket boundary. ConciergeUsageAggregate
          # has carried a coarse success/fallback/blank/error +outcome+ column
          # since before the typed resolutions existed, and Web chat derives
          # that bucket from the resolution. The membership below is frozen for
          # legacy comparability: the buckets are not renamed, none is added
          # and no resolution moves between them. What changed in Task 9b is
          # which resolution a refusal CARRIES, not which bucket a resolution
          # maps to. SAFETY_GUIDANCE adds a new fallback label: emergency-stage
          # turns previously labelled answered move to it only from the release
          # onward. Preserve old rows and annotate that measurement boundary;
          # never compare the old/new success numerator as an unchanged metric.
          SUCCEEDED = (VALUES - UNRESOLVED).freeze

          module_function

          def valid?(resolution)
            VALUES.include?(resolution)
          end

          # Did the turn answer the question or advance the task? This is the
          # one definition of the historical "success" bucket; the web chat
          # controller reads it rather than keeping a second list.
          def succeeded?(resolution)
            SUCCEEDED.include?(resolution)
          end

          def unresolved?(resolution)
            UNRESOLVED.include?(resolution)
          end

          # True only when the label is a statement about a dependency being
          # unusable. Never infer answer quality or a citizen rating from it.
          def source_health?(resolution)
            SOURCE_HEALTH.include?(resolution)
          end

          # A clarification is still mid-task: it keeps the pending slot and the
          # count that bounds how often Milica may ask again.
          def settles_task?(resolution)
            resolution != CLARIFICATION
          end

          # The hand-off offered AT the clarification limit is the exception:
          # the slot it was asking for stays pending.
          def retains_pending_slot?(resolution, clarification_count:)
            resolution == HANDOFF && clarification_count == 2
          end

          def retains_clarification_count?(resolution)
            resolution == HANDOFF
          end

          # The offer to resume a suspended task is made once per suspension,
          # on any turn that is not itself a clarification.
          def offers_resume?(resolution)
            resolution != CLARIFICATION
          end

          # A read the source answered (status "ok" or "stale") that carried no
          # facts at all. There is nothing to tell the citizen, so the turn
          # ends with the "no verified data" refusal.
          #
          # +stale: true+ is a SOURCE-HEALTH statement: the source answered
          # with data that no longer covers the question. +stale: false+ is a
          # COVERAGE statement: the source is fine, we simply hold no verified
          # record. They stay separate labels because they carry different
          # retry advice and different operator work.
          def empty_available_read(stale:)
            stale ? SOURCE_UNAVAILABLE : UNSUPPORTED
          end

          # A read that reported status "empty".
          #
          # +complete: true+ means the reader produced a scoped zero-result
          # answer naming what was checked, for which areas and over which
          # window (Dialogue::PublicCatalogEmptyAnswer). The citizen asked and
          # was told the verified answer, which happens to be none: ANSWERED.
          #
          # +complete: false+ means the turn fell back to the "no verified
          # data" refusal. Nothing was answered.
          #
          # +checked_zero: true+ is the SAME answer reached from the other
          # side: the reader composed no scoped answer of its own, but its
          # warnings state that the source was reached and holds nothing for
          # the area and period asked about (Dialogue::CheckedZero). That is a
          # verified negative, so it is ANSWERED — and the refusal sentence is
          # then the false one and must not be printed beside it. Keeping the
          # two arguments separate keeps the plain fallback refusal exactly
          # where Task 9b put it.
          def empty_read(complete:, checked_zero: false)
            return ANSWERED if complete || checked_zero

            UNSUPPORTED
          end
        end
      end
    end
  end
end
