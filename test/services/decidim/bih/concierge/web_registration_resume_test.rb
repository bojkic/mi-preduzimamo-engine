# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/hash/except"
require_relative "../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../app/controllers/concerns/decidim/bih/concierge/web_registration_resume"

module Decidim
  module Bih
    module Concierge
      class WebRegistrationResumeTest < Minitest::Test
        class Harness
          include WebRegistrationResume
          attr_accessor :user, :bridge, :store, :context
          attr_reader :session, :errors

          def initialize
            @session = {}
            @errors = []
          end

          def current_organization_user = user

          def trusted_dialogue_context = context

          def registration_handoff_bridge = bridge

          def registration_dialogue_store = store

          def registration_resume_failure(error) = errors << error.class
        end

        def setup
          @context = Dialogue::Contracts::TrustedContext.new(
            organization_id: 71, actor_id: 17, conversation_key: "b" * 64, now: Time.utc(2026, 9, 9, 12)
          )
          @harness = Harness.new
          @harness.user = Object.new
          @harness.context = @context
          @calls = []
          calls = @calls
          @bridge = Object.new
          @bridge.define_singleton_method(:consume) do |**args|
            calls << args
            { "active_task" => "ask_information" }
          end
          @bridge.define_singleton_method(:prepare) do |**args|
            calls << args
            args.fetch(:reply)
          end
          @harness.bridge = @bridge
          @state = Dialogue::StateStore.new.empty_state(@context).merge(
            "active_task" => "sign_in", "topic" => "account", "version" => 4
          )
          @stored = @state.merge("version" => 5)
          @store = Object.new
          test = self
          @store.define_singleton_method(:read) { |**| test.instance_variable_get(:@stored) }
          @harness.store = @store
        end

        def reply
          outcome = Dialogue::ProcedureRunner::Result.new(
            state: @state, reply: nil, resolution: "handoff", fact_ids: [], handoff_offered: true, handoff_completed: false
          )
          answer = Responder::Reply.new(text: "Sign in: /users/sign_in", report: nil)
          answer.define_singleton_method(:dialogue_outcome) { outcome }
          answer
        end

        def test_only_actual_signed_in_non_control_turns_reach_host_consume
          ["odustani", "/clear", "moj kod je 123456"].each do |text|
            assert_nil @harness.send(:registration_resume_for, text)
          end
          assert_empty @calls
          @harness.user = nil
          assert_nil @harness.send(:registration_resume_for, "nastavi")
          assert_empty @calls
          @harness.user = Object.new
          assert_equal({ "active_task" => "ask_information" }, @harness.send(:registration_resume_for, "nastavi"))
          assert_same @harness.user, @calls.last.fetch(:user)
          assert_equal 71, @calls.last.fetch(:context).organization_id
        end

        def test_coordinator_preserves_independent_emergency_sentence_boundaries
          raw = "Kontejner ne gori. Voda raste."
          assert Dialogue::Coordinator.safety?(raw, Decidim::Bih::Text.fold(raw))
          raw = "Kontejner ne gori i niko nije zarobljen."
          refute Dialogue::Coordinator.safety?(raw, Decidim::Bih::Text.fold(raw))
        end

        def test_authenticated_return_can_continue_the_retained_own_report_query_without_model_guessing
          state = @state.merge("active_task" => "report_status", "topic" => "report", "entities" => { "query" => "Moje prijave" })
          input = Dialogue::Coordinator.allocate.send(:fast_understanding, "nastavi", state)
          assert_equal "report_status", input.action
          assert_equal "continue", input.operation
          refute input.needs_clarification
        end

        def test_only_exact_committed_handoff_revision_is_decorated
          answer = reply
          assert_same answer, @harness.send(:prepare_registration_return, answer)
          assert_equal 5, @calls.last.fetch(:state).fetch("version")
          assert_operator @calls.last.fetch(:context).deadline.remaining_seconds, :<=, 0.5
          @calls.clear
          @stored = @state
          assert_same answer, @harness.send(:prepare_registration_return, answer)
          assert_empty @calls
          @stored = @state.merge("version" => 5, "topic" => "report")
          assert_same answer, @harness.send(:prepare_registration_return, answer)
          assert_empty @calls
          untyped = Responder::Reply.new(text: "I registered you", report: nil)
          assert_same untyped, @harness.send(:prepare_registration_return, untyped)
          assert_empty @calls
        end

        def test_restoration_is_fresh_cas_and_does_not_import_evidence_or_confirmation
          writes = []
          actual = Dialogue::StateStore.new
          @store.define_singleton_method(:empty_state) { |context| actual.empty_state(context) }
          @store.define_singleton_method(:write) do |**args|
            actual.validate(context: args.fetch(:context), state: args.fetch(:state))
            writes << args
            :conflict
          end
          task = @state.slice(*Dialogue::StateStore::TASK_KEYS).merge(
            "active_task" => "report_problem", "topic" => "report",
            "draft" => { "old" => "confirmation" }, "report_handoff_offered" => true,
            "prior_evidence" => { "private" => "must not transfer" }, "version" => 99
          )
          assert_equal :conflict, @harness.send(:restore_registration_task, task)
          assert_equal 1, writes.length
          assert_equal 0, writes.first.fetch(:expected_version)
          fresh = writes.first.fetch(:state)
          assert_equal 0, fresh.fetch("version")
          assert_nil fresh["draft"]
          assert_nil fresh["prior_evidence"]
          refute fresh["report_handoff_offered"]
          assert_equal @context.actor_id, writes.first.fetch(:context).actor_id
        end

        def test_bridge_failures_leave_original_reply_and_do_not_retry
          @bridge.define_singleton_method(:prepare) { |**| raise IOError }
          answer = reply
          assert_same answer, @harness.send(:prepare_registration_return, answer)
          assert_equal [IOError], @harness.errors
        end
      end
    end
  end
end
