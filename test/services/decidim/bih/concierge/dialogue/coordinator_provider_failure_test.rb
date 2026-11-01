# frozen_string_literal: true

require "test_helper"
require "logger"
require "stringio"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/understand"
require_relative "../../../../../../app/services/decidim/bih/concierge/answer_outcome"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A failed understanding provider is reported as such: it never reads
        # as an unclear citizen, never writes state and never leaks a detail.
        # The coordinator itself emits no metrics event; the reply boundary
        # records the outcome from the resolution, so the offline evaluation's
        # no-side-effect probe stays clean on a provider failure.
        class CoordinatorProviderFailureTest < Minitest::Test
          NOW = Time.utc(2026, 9, 12, 12)
          QUESTION = "Kako da platim parking?"

          class RecordingStateStore
            attr_reader :writes

            def initialize(state)
              @state = state
              @writes = []
            end

            def read(**) = @state

            def write(context:, state:, expected_version:)
              @writes << { context:, state:, expected_version: }
              :saved
            end
          end

          class YieldingAdmission
            def with_slot(**)
              AdmissionControl::Result.new(status: :admitted, value: yield)
            end
          end

          class FixedStatusRuntime
            def initialize(status) = @status = status

            def call = AdmissionControl::Result.new(status: @status)
          end

          def setup
            @previous_backend = I18n.backend
            @previous_load_path = I18n.load_path
            @previous_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path = [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.send(:init_translations)
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "c" * 64, now: NOW,
                                                     capabilities: %w(public_reads report_guidance registration_handoff))
            @store = RecordingStateStore.new(StateStore.new(redis: Object.new).empty_state(@context))
            @events = []
            @subscriber = ActiveSupport::Notifications.subscribe(AnswerOutcome::EVENT) { |*, payload| @events << payload }
            @procedure_calls = 0
          end

          def teardown
            ActiveSupport::Notifications.unsubscribe(@subscriber)
            I18n.backend = @previous_backend
            I18n.load_path = @previous_load_path
            I18n.available_locales = @previous_locales
          end

          def test_provider_unavailable_is_its_own_resolution_and_writes_no_state
            Understand::ProviderUnavailable::REASONS.each do |reason|
              @events.clear
              result = answer(coordinator(failure: Understand::ProviderUnavailable.new(reason)))

              assert_equal "provider_unavailable", result.resolution, reason
              assert_equal "fallback", result.reply.answer_intent, reason
              assert_equal provider_unavailable_copy, result.reply.text, reason
              assert_nil result.reply.report
              assert_nil result.state
              assert_empty result.fact_ids
              assert_empty @store.writes, "#{reason} must not write state"
              assert_empty @events, "#{reason} must not emit a metrics event from the coordinator"
            end
            assert_equal 0, @procedure_calls
          end

          def test_the_real_runtime_lets_a_provider_failure_through_to_the_coordinator
            runtime = Coordinator::Runtime.new(admission: YieldingAdmission.new, timeout: 5.0)

            result = answer(coordinator(failure: Understand::ProviderUnavailable.new("timeout"), runtime:))

            assert_equal "provider_unavailable", result.resolution
            assert_empty @store.writes
            assert_nil Thread.current[Coordinator::Runtime::THREAD_KEY]
          end

          def test_unexpected_errors_still_read_as_context_unavailable_without_a_metrics_event
            result = answer(coordinator(failure: RuntimeError.new("secret detail")))

            assert_equal "unsupported", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.context_unavailable", locale: :sr, raise: true), result.reply.text
            assert_empty @store.writes
            assert_empty @events
          end

          def test_runtime_swallows_unexpected_errors_into_unavailable_and_logs_the_class_only
            io = StringIO.new
            runtime = Coordinator::Runtime.new(admission: YieldingAdmission.new, timeout: 5.0)

            admitted = Coordinator::Runtime.stub(:default_logger, Logger.new(io)) { runtime.call { raise "secret detail" } }

            assert_equal :unavailable, admitted.status
            assert_includes io.string, "[MilicaCoordinator] stage=runtime error=RuntimeError"
            refute_includes io.string, "secret detail"
            assert_empty @events
          end

          def test_capacity_refusal_resolves_as_busy
            result = answer(coordinator(runtime: FixedStatusRuntime.new(:capacity)))

            assert_equal "busy", result.resolution
            assert_equal I18n.t("decidim.bih.dialogue.busy", locale: :sr, raise: true), result.reply.text
            assert_equal "fallback", result.reply.answer_intent

            unavailable = answer(coordinator(runtime: FixedStatusRuntime.new(:unavailable)))
            assert_equal "unsupported", unavailable.resolution
          end

          def test_failure_log_line_carries_a_closed_provider_reason
            io = StringIO.new
            logger = Logger.new(io)
            error = Understand::ProviderUnavailable.new("transport")

            Coordinator::Runtime.record_failure(stage: "understanding", error: error, logger:)

            assert_includes io.string, "[MilicaCoordinator] stage=understanding error=Decidim::Bih::Concierge::Dialogue::Understand::ProviderUnavailable"
            assert_includes io.string, "reason=provider_transport"
            assert_empty @events
          end

          def test_failure_log_line_never_carries_the_error_message
            io = StringIO.new
            Coordinator::Runtime.record_failure(stage: "runtime", error: RuntimeError.new("+38765123456 token=abc"), logger: Logger.new(io))

            assert_includes io.string, "stage=runtime error=RuntimeError"
            refute_includes io.string, "38765123456"
            refute_includes io.string, "token=abc"
          end

          def test_contract_and_provider_unknown_messages_are_never_logged
            provider_error = Understand::ProviderUnavailable.new("transport")
            provider_error.define_singleton_method(:reason) { "secret token=private-value" }
            [Contracts::Invalid.new("secret token=private-value"), provider_error].each do |error|
              io = StringIO.new
              Coordinator::Runtime.record_failure(stage: "coordinator", error:, logger: Logger.new(io))
              refute_includes io.string, "secret"
              refute_includes io.string, "private-value"
              assert_match(/reason=(?:contract_invalid|provider_unavailable)/, io.string)
            end
            assert_equal "contract_text", Coordinator::Runtime.failure_reason(Contracts::Invalid.new("Expected bounded contract text"))
            assert_equal "contract_provenance", Coordinator::Runtime.failure_reason(Contracts::Invalid.new("Entity provenance mismatch"))
          end

          def test_recording_a_failure_never_raises
            broken = Object.new
            broken.define_singleton_method(:warn) { |*| raise IOError, "log closed" }

            assert_nil Coordinator::Runtime.record_failure(stage: "runtime", error: RuntimeError.new("x"), logger: broken)
          end

          # A cancellation never consults the provider, so a protected control
          # reply can only meet a capacity refusal; it must keep its resolution.
          def test_protected_cancellation_keeps_the_safety_reply_when_capacity_is_exhausted
            message = Data.define(:text) { def safety_signal? = true }.new("Odustani. Kako da platim parking?")

            result = answer(coordinator(runtime: FixedStatusRuntime.new(:capacity)), message:)

            assert_equal "safety_guidance", result.resolution
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.busy", locale: :sr, raise: true)
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.safety", locale: :sr, raise: true)
            assert_equal "safety", result.reply.answer_intent
            assert_empty @store.writes
          end

          private

          # The reply locale follows I18n.locale for a Latin message; the
          # dialogue copy under test is the Serbian one.
          def answer(coordinator, message: QUESTION)
            I18n.with_locale(:sr) { coordinator.call(message:, context: @context) }
          end

          def provider_unavailable_copy
            fallback = I18n.t("decidim.bih.dialogue.context_unavailable", locale: :sr, raise: true)
            I18n.t("decidim.bih.dialogue.provider_unavailable", locale: :sr, default: fallback)
          end

          def coordinator(failure: nil, runtime: nil)
            understanding = ->(**) { raise failure || RuntimeError.new("understanding must not run") }
            read_port = lambda do |**|
              @procedure_calls += 1
              Contracts::ReadResult.new(status: "empty")
            end
            procedures = ProcedureRunner.new(
              read_port:,
              registration_port: ->(**) { raise "Unexpected account action" },
              destinations: { report: "/report", neighborhood: "/board", account: "/account", support: "/help" }
            )
            Coordinator.new(understanding:, procedures:, state_store: @store,
                            runtime: runtime || Coordinator::Runtime.new(admission: YieldingAdmission.new, timeout: 5.0))
          end
        end
      end
    end
  end
end
