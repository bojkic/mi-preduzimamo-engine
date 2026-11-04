# frozen_string_literal: true

require "json"
require_relative "../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Offline characterisation of the whole dialogue turn, used to prove that
        # the Task 0 seam extraction (DeterministicRoutes, PreModelStages,
        # FactRenderer, Resolution) changed no behaviour.
        #
        # It drives the real Coordinator and the real ProcedureRunner against the
        # engine's own test doubles — an in-memory Redis, a recording read port
        # and a canned registration port. Nothing here talks to production, to a
        # model provider or to a network.
        #
        # The dump is deterministic: a fixed clock, a fixed conversation key, a
        # fixed locale and fixed canned read results. Byte-compare it before and
        # after a refactor; a single changed character is a behaviour change.
        #
        # Regenerate the committed baseline with:
        #   CHARACTERISATION_WRITE=1 bundle exec ruby -Itest \
        #     test/services/decidim/bih/concierge/dialogue/characterisation_test.rb
        #
        # The state projection below deliberately omits the reserved emergency
        # continuity key: Task 0 adds it to the state schema, nothing writes it,
        # and its own contract test (safety_context_contract_test.rb) covers it.
        module Characterisation
          NOW = Time.utc(2026, 9, 14, 10, 30)
          CONVERSATION_KEY = "f" * 64
          ORGANIZATION_ID = 1
          ACTOR_ID = 7
          CAPABILITIES = %w(public_reads neighborhood_reads own_report_reads report_guidance registration_handoff).freeze
          DESTINATIONS = {
            report: "/mi/prijavi", account: "/mi/moj-nalog", neighborhood: "/mi/komsiluk", support: "/pages/pomoc"
          }.freeze
          LOCALE_FILES = %w(
            decidim_bih_dialogue.yml decidim_bih_dialogue_completion.yml
            decidim_bih_dialogue_neighborhood.yml decidim_bih_utility_scope.yml sr.yml
          ).freeze
          STATE_PROJECTION = %w(
            version active_task topic pending_slot entities entity_provenance locale
            clarification_count report_handoff_offered resume_offered
          ).freeze

          # An in-memory stand-in for the Redis the state store CASes against.
          class FakeRedis
            def initialize
              @values = {}
            end

            def get(key) = @values[key]

            def del(key)
              @values.delete(key)
              1
            end

            def eval(script, keys:, argv:)
              case script
              when StateStore::WRITE_SCRIPT then write(keys.first, argv)
              when StateStore::RESET_SCRIPT then reset(keys.first, argv.first)
              else raise "Unexpected script"
              end
            end

            private

            def write(key, argv)
              stored = @values[key]
              version = stored ? JSON.parse(stored).fetch("version") : 0
              return 0 unless version == argv.first

              @values[key] = argv[1]
              1
            end

            def reset(key, expected)
              return 0 unless @values[key] == expected

              @values.delete(key)
              1
            end
          end

          # The real Runtime needs admission control and a Redis lease. The turn
          # budget it hands the coordinator is the only part a characterisation
          # run needs, so it runs inline with a full budget.
          class InlineRuntime
            def call
              AdmissionControl::Result.new(status: :admitted, value: yield(TurnBudget.new(timeout: 10.0)))
            end
          end

          # The read port the runner calls. It answers the ordinary read and the
          # four optional follow-up reads, so the pre-model stages that ask
          # +respond_to?+ before firing are reachable from a characterised turn.
          class RecordingReadPort
            EMPTY = -> { Contracts::ReadResult.new(status: "empty") }

            def initialize(step, reads)
              @step = step
              @reads = reads
            end

            def call(**arguments)
              @reads << arguments
              @step.fetch(:read) { EMPTY.call }
            end

            def transport_walking_directions(stop_id:, context:, locale:)
              @reads << { follow_up: "walking", stop_id:, locale:, context: }
              @step.fetch(:walking_read) { EMPTY.call }
            end

            def procedure_follow_up(procedure_id:, focus:, context:, locale:)
              @reads << { follow_up: "procedure", procedure_id:, focus:, locale:, context: }
              @step.fetch(:procedure_read) { EMPTY.call }
            end

            def service_follow_up(source_id:, focus:, context:, locale:)
              @reads << { follow_up: "service", source_id:, focus:, locale:, context: }
              @step.fetch(:service_read) { EMPTY.call }
            end

            # nil means "no reference answer", which is how the coordinator's
            # public-information stage falls through to the rest of the turn.
            def public_reference_follow_up(source_ids:, message:, context:, locale:)
              @reads << { follow_up: "reference", source_ids:, message:, locale:, context: }
              @step.fetch(:reference_read, nil)
            end
          end

          Message = Data.define(:text, :conversation_context, :dialogue_location)
          SafetyMessage = Data.define(:text, :conversation_context, :dialogue_location) do
            def safety_signal? = true
          end

          module_function

          # The dumped transcript for the whole corpus, as one String.
          def run
            with_locales do
              Corpus.cases.map { |example| dump_case(example) }.join("\n")
            end
          end

          def with_locales
            previous = { backend: I18n.backend, load_path: I18n.load_path, available: I18n.available_locales, locale: I18n.locale }
            I18n.load_path = LOCALE_FILES.map { |name| File.expand_path("../../../../config/locales/#{name}", __dir__) }
            I18n.backend = I18n::Backend::Simple.new
            I18n.available_locales = Contracts::LOCALES
            I18n.locale = :sr # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.backend.send(:init_translations)
            yield
          ensure
            I18n.backend = previous.fetch(:backend)
            I18n.load_path = previous.fetch(:load_path)
            I18n.available_locales = previous.fetch(:available)
            # The restored load path may no longer offer the locale this process
            # started in, and enforcement would then refuse to put it back.
            enforcing = I18n.enforce_available_locales
            I18n.enforce_available_locales = false
            I18n.locale = previous.fetch(:locale) # rubocop:disable Rails/I18nLocaleAssignment -- paired setup/teardown restores the process locale
            I18n.enforce_available_locales = enforcing
          end

          def dump_case(example)
            lines = ["== #{example.fetch(:name)}"]
            execute(example).each_with_index do |run, index|
              lines.concat(dump_step(example.fetch(:steps).fetch(index), run, index))
            end
            lines << "== end #{example.fetch(:name)}"
            "#{lines.join("\n")}\n"
          end

          def dump_step(step, run, index)
            result = run.fetch(:result)
            lines = ["-- turn #{index + 1}", "prompt: #{stable_inspect(step.fetch(:text))}"]
            lines << "understanding: #{understanding_token(step)}"
            lines << "model_calls: #{run.fetch(:model_calls)}"
            lines << "reads: #{stable_inspect(run.fetch(:reads).map { |read| read_token(read) })}"
            lines << "resolution: #{stable_inspect(result.resolution)}"
            lines << "answer_intent: #{stable_inspect(result.reply.answer_intent)}"
            lines << "tone: #{stable_inspect(result.reply.tone)}"
            lines << "quick_replies: #{stable_inspect(result.reply.quick_replies)}"
            lines << "report: #{stable_inspect(result.reply.report)}"
            lines << "fact_ids: #{stable_inspect(result.fact_ids)}"
            lines << "handoff: offered=#{result.handoff_offered} completed=#{result.handoff_completed}"
            lines << "state: #{state_token(result.state)}"
            lines << "stored: #{state_token(run.fetch(:stored))}"
            lines << "reply:"
            lines << result.reply.text.to_s
          end

          # Every step of a case shares one conversation: the same store, the
          # same trusted context and therefore the state the previous step saved.
          def execute(example)
            redis = FakeRedis.new
            store = StateStore.new(redis:)
            context = trusted_context(example)
            seed_state(store, context, example)
            example.fetch(:steps).map do |step|
              reads = []
              model_calls = []
              coordinator = build_coordinator(step, store:, reads:, model_calls:)
              result = coordinator.call(message: build_message(step), context:)
              { result:, reads:, model_calls: model_calls.size, stored: store.read(context:) }
            end
          end

          def trusted_context(example)
            Contracts::TrustedContext.new(
              organization_id: ORGANIZATION_ID, conversation_key: CONVERSATION_KEY,
              actor_id: example.fetch(:actor_id, ACTOR_ID), account_state: example.fetch(:account_state, "verified"),
              capabilities: CAPABILITIES, now: NOW
            )
          end

          def build_message(step)
            klass = step.fetch(:safety_signal, false) ? SafetyMessage : Message
            klass.new(text: step.fetch(:text), conversation_context: step.fetch(:history, []),
                      dialogue_location: step.fetch(:location, nil))
          end

          def seed_state(store, context, example)
            seed = example.fetch(:state, nil)
            return unless seed

            state = store.empty_state(context).merge(seed)
            raise "Characterisation fixture state rejected" unless store.write(context:, state:, expected_version: 0) == :saved
          end

          def build_coordinator(step, store:, reads:, model_calls:)
            understanding = lambda do |**arguments|
              model_calls << arguments
              step.fetch(:understanding, DEFAULT_UNDERSTANDING).call
            end
            procedures = ProcedureRunner.new(
              read_port: RecordingReadPort.new(step, reads),
              registration_port: ->(**) { step.fetch(:handoff, DEFAULT_HANDOFF) },
              destinations: DESTINATIONS
            )
            Coordinator.new(understanding:, procedures:, state_store: store, runtime: InlineRuntime.new)
          end

          DEFAULT_UNDERSTANDING = lambda do
            Contracts::Understanding.parse(action: "help", topic: "unknown", entities: {}, operation: "clarify",
                                           needs_clarification: true, secondary: nil, locale: "sr")
          end
          DEFAULT_HANDOFF = Contracts::HandoffResult.new(account_state: "registered", next_step: "verification",
                                                         destination: "/mi/moj-nalog")

          def understanding_token(step)
            return "route" unless step.has_key?(:understanding)

            input = step.fetch(:understanding).call
            "#{input.action}/#{input.topic}/#{input.operation}"
          end

          def read_token(read)
            return "#{read.fetch(:action)}/#{read.fetch(:topic)}/#{stable_inspect(read.fetch(:entities).sort.to_h)}/#{read.fetch(:locale)}" unless read[:follow_up]

            details = read.except(:follow_up, :context, :locale).sort.to_h
            "follow_up:#{read.fetch(:follow_up)}/#{stable_inspect(details)}/#{read.fetch(:locale)}"
          end

          # Keep this historical transcript independent of Ruby 3.4's changed
          # Hash#inspect spacing and symbol-key syntax. Values, order and reply
          # text remain exact; the committed behaviour baseline is unchanged.
          def stable_inspect(value)
            case value
            when Hash
              "{#{value.map { |key, item| "#{stable_inspect(key)}=>#{stable_inspect(item)}" }.join(", ")}}"
            when Array
              "[#{value.map { |item| stable_inspect(item) }.join(", ")}]"
            else
              value.inspect
            end
          end

          def state_token(state)
            return "nil" unless state

            state.slice(*STATE_PROJECTION).merge(
              "suspended_task" => state["suspended_task"] ? state["suspended_task"]["active_task"] : nil,
              "draft" => state["draft"] ? "present" : nil,
              "prior_evidence" => state["prior_evidence"] ? state["prior_evidence"]["kind"] : nil
            ).then { |projection| stable_inspect(projection) }
          end
        end
      end
    end
  end
end

require_relative "dialogue_characterisation_corpus"
