# frozen_string_literal: true

require_relative "service_follow_up_question"
require_relative "procedure_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # THE ordered list of stages the coordinator walks BEFORE the
        # understanding/model call. A stage answers the turn deterministically
        # or declines and lets the next one try; only when every stage declines
        # does the coordinator reach fast understanding and then the provider.
        #
        # == Registration point and ordering guarantee
        #
        # +register+ is the single registration point. Stages run in
        # registration order and the FIRST stage that returns a result ends the
        # turn. Registration appends by default, so a stage added later runs
        # last; pass +before:+ or +after:+ with an existing stage name to place
        # it exactly (a stage that must outrank everything registers
        # <tt>before: "resume_nothing"</tt>). Registering a name that already
        # exists REPLACES it in place, which keeps the list stable when a file
        # is loaded twice.
        #
        # A stage registered from another file only applies once that file is
        # LOADED. Production eager-loads app/services, but the host's test
        # environment does not (config.eager_load is CI-only), so do not rely on
        # autoloading: put the +register+ call at the top level of your file and
        # add one +require_relative+ for it beside the built-ins at the bottom of
        # this file. That is the whole edit — the added line also makes the new
        # stage's position in the order explicit and reviewable.
        #
        # The built-in stages at the bottom of this file are registered in
        # exactly the order Coordinator#execute_with_state ran them before this
        # list existed: resume_nothing, public_information_follow_up,
        # transport_walking_follow_up, prior_evidence_follow_up,
        # service_follow_up, procedure_fee_follow_up. Do not reorder them —
        # the order is behaviour, and so is each stage's deadline handling.
        #
        # == Stage contract
        #
        # A stage handler receives a Turn and returns nil to decline, or a
        # ProcedureRunner::Result to end the turn with. It reaches the
        # coordinator only through the Turn: the procedures object, the
        # deadline, and the coordinator helpers bound into Support. It
        # gets no other access, no model call and no state write of its own —
        # a stage that wants to save state returns a candidate through
        # +turn.accept+, which is the coordinator's single CAS write.
        module PreModelStages
          Stage = Data.define(:name, :handler)

          # The coordinator helpers a stage may use, as bound methods rather
          # than the coordinator itself.
          #
          # +retain_answer+ defaults to a no-op that hands the state straight
          # back, so a caller that builds a Support for a stage which retains
          # nothing (and every test double that predates the hook) keeps
          # working unchanged. The coordinator always supplies the real one.
          NO_RETENTION = ->(state:, **) { state }
          Support = Data.define(
            :procedures, :cancelled, :prior_evidence_kind, :accept, :unavailable,
            :resume_nothing, :resume_with_nothing_suspended, :walking_stop_request, :retain_answer
          ) do
            def initialize(retain_answer: NO_RETENTION, **rest) = super
          end

          Turn = Data.define(:message, :context, :state, :support) do
            def procedures = support.procedures

            def deadline_expired? = context.deadline.expired?

            # The coordinator's own "context unavailable" failure result.
            def unavailable = support.unavailable.call(message, "context_unavailable")

            def accept(candidate) = support.accept.call(candidate, message:, context:, state:)

            def cancelled? = support.cancelled.call(message)

            def prior_evidence_kind = support.prior_evidence_kind.call(message)

            def resume_nothing = support.resume_nothing.call(message, state)

            def resume_with_nothing_suspended? = support.resume_with_nothing_suspended.call(message, state)

            def walking_stop_request? = support.walking_stop_request.call(message)

            # Retain WHAT this stage just answered, apart from the task state
            # it deliberately does not touch. Returns the state to report -
            # the retained one when the CAS took, the untouched one when it
            # did not. See Coordinator#retain_answer_context.
            def retain_answer(**attributes) = support.retain_answer.call(state:, context:, **attributes)

            # The raw citizen text, unstripped, exactly as the coordinator read
            # it before these stages existed.
            def text = message.respond_to?(:text) ? message.text.to_s : message.to_s
          end

          class << self
            # The registration point. See the ordering guarantee above.
            def register(name, before: nil, after: nil, &handler)
              raise ArgumentError, "Stage name required" unless name.is_a?(String) && !name.empty?
              raise ArgumentError, "Stage handler required" unless handler

              stage = Stage.new(name:, handler:)
              existing = stages.index { |candidate| candidate.name == name }
              return stages[existing] = stage if existing

              stages.insert(position(before:, after:), stage)
              stage
            end

            def stages
              @stages ||= []
            end

            def stage_names
              stages.map(&:name)
            end

            # The first stage result, or nil when every stage declines.
            def walk(turn)
              stages.each do |stage|
                result = stage.handler.call(turn)
                return result if result
              end
              nil
            end

            private

            def position(before:, after:)
              anchor = before || after
              return stages.length unless anchor

              index = stages.index { |candidate| candidate.name == anchor }
              raise ArgumentError, "Unknown stage #{anchor}" unless index

              before ? index : index + 1
            end
          end

          # THE BUILT-IN STAGES, in the order the coordinator ran them before
          # extraction. Their bodies are unchanged, including which of them
          # check the deadline and which accept a nil candidate.

          # "nastavi" with nothing to resume is answered deterministically and
          # keeps the state as it is: no model call, no CAS write.
          register("resume_nothing") do |turn|
            turn.resume_nothing if turn.resume_with_nothing_suspended?
          end

          register("public_information_follow_up") do |turn|
            if !turn.cancelled? && turn.procedures.respond_to?(:public_information_follow_up)
              candidate = turn.procedures.public_information_follow_up(state: turn.state, context: turn.context, message: turn.message)
              if turn.deadline_expired?
                turn.unavailable
              elsif candidate
                turn.accept(candidate)
              end
            end
          end

          register("transport_walking_follow_up") do |turn|
            if turn.walking_stop_request?
              candidate = turn.procedures.transport_walking_follow_up(state: turn.state, context: turn.context, message: turn.message)
              if turn.deadline_expired?
                turn.unavailable
              elsif candidate
                turn.accept(candidate)
              end
            end
          end

          # This stage deliberately has no deadline check and no nil guard: a
          # retained-evidence follow-up always answers from state it already has.
          register("prior_evidence_follow_up") do |turn|
            kind = turn.prior_evidence_kind
            if kind
              candidate = turn.procedures.prior_evidence_follow_up(kind:, state: turn.state, context: turn.context, message: turn.message)
              turn.accept(candidate)
            end
          end

          register("service_follow_up") do |turn|
            if ServiceFollowUpQuestion.focus(turn.text) && ServiceFollowUpQuestion.retained_source_id(state: turn.state, context: turn.context)
              candidate = turn.procedures.service_follow_up(state: turn.state, context: turn.context, message: turn.message)
              if turn.deadline_expired?
                turn.unavailable
              elsif candidate
                turn.accept(candidate)
              end
            end
          end

          register("procedure_fee_follow_up") do |turn|
            if ProcedureQuestion.fee_follow_up?(turn.text) && ProcedureQuestion.retained_id(state: turn.state, context: turn.context)
              candidate = turn.procedures.procedure_fee_follow_up(state: turn.state, context: turn.context, message: turn.message)
              if turn.deadline_expired?
                turn.unavailable
              elsif candidate
                turn.accept(candidate)
              end
            end
          end
        end

        # REGISTERED STAGES FROM OTHER FILES. Autoloading will not run a
        # top-level +register+ in the host's test environment, so each stage is
        # required here, after the built-ins. Each stage declares its own
        # position through the +before:+/+after:+ it passes, so the order below
        # is load order, not evaluation order.
        #
        # Task 2's emergency stage registers +before: "resume_nothing"+ and is
        # therefore the FIRST stage the coordinator walks — it must outrank
        # retained evidence, follow-ups, drafts and cancellation wording.
        require_relative "emergency_stage"
        require_relative "public_information_stage"
        # Task 5 places its two stages around Task 3b's card: the account answer
        # +before+ it (a specific reviewed answer outranks the general privacy
        # card) and the report explanations +after+ it. Both anchor on a stage
        # that must already be registered, hence the load order below.
        require_relative "account_phone_visibility_stage"
        require_relative "trusted_conversation_stage"
        require_relative "location_help_stage"
        require_relative "report_guidance"
        require_relative "transport_location_preference_stage"
        require_relative "feedback_recovery_stage"
        # R6 answers a brevity request about a card that has already been
        # given, and registers +after: "procedure_fee_follow_up"+ — LAST, so
        # every stage above keeps the turns it answers today and only a turn
        # that would otherwise have reached the provider gets there.
        require_relative "card_presentation_stage"
      end
    end
  end
end
