# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # 2026-10-21: a Sidekiq restart cut a case-agent call off mid-request and
      # the re-run found its own "generating" row too fresh to touch, so the
      # proposal stayed generating. These pin resume, sweep and no-steal.
      class AiCaseAgentInterruptionTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        # Sidekiq::Shutdown is an Interrupt, which no StandardError rescue sees.
        Shutdown = defined?(::Sidekiq::Shutdown) ? ::Sidekiq::Shutdown : Class.new(Interrupt)

        class Client
          attr_accessor :on_call

          def initialize(value) = @value = value

          def generate_content(**)
            on_call&.call
            @value.deep_dup
          end
        end

        # Counts every provider call, including the one that was interrupted.
        class Meter
          attr_reader :purposes

          def initialize = @purposes = []

          def call(client:, purpose:, **args)
            @purposes << purpose
            client.generate_content(**args)
          end
        end

        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: "Kontejner je polomljen kod škole", address: "Ulica 1", category: "ostalo")
          # After creation, so intake does not queue a generation of its own.
          Setting.put(@organization, "report_review", "case_agent", "shadow")
          clear_enqueued_jobs
          @meter = Meter.new
          @client = Client.new(valid)
          WorkerShutdown.reset!
        end

        teardown { WorkerShutdown.reset! }

        def valid
          { "assessment" => { "in_scope" => true, "kind" => "kvar", "hazard_signal" => false, "hazard_quote" => "" },
            "missing_fields" => [], "citizen_message" => { "template_key" => "", "composed_text" => "", "slots" => { "text" => "", "date" => "" } },
            "duplicate" => { "reference" => "", "quote_new" => "", "quote_existing" => "" },
            "routing" => { "category" => "ostalo", "recipient_key" => "", "guidance_key" => "" },
            "city_message" => { "kind" => "initial", "text" => "", "evidence_item_ids" => [] },
            "service_response" => { "type" => "unclear", "quote" => "", "planned_date_quote" => "", "file_numbers" => [], "requested_evidence" => [] },
            "proposed_action" => "review", "obligation_updates" => [],
            "facts" => [{ "text" => "Kontejner je polomljen", "source_id" => "original", "quote" => "Kontejner je polomljen" }],
            "observations" => [], "rationale" => "Predlažem pregled.", "uncertainties" => [] }
        end

        def agent(**)
          Ai::CaseAgent.new(@report, client: @client, usage: @meter, **)
        end

        # The first provider call is cut off the way a hard stop cuts it off.
        def interrupt_first_call(owner)
          calls = 0
          @client.on_call = -> { raise Shutdown, "hard stop" if (calls += 1) == 1 }
          assert_raises(Shutdown) { agent(lease_owner: owner).call }
          @client.on_call = nil
          proposal
        end

        def proposal = @report.review_proposals.sole.reload

        def leases
          Ai::CaseAgent.lease_events(@report, proposal).map { |event| event.metadata["lease"] }
        end

        # Jobs build their own agent; route them to the counting fake client.
        def with_fake_provider(&)
          build = Ai::CaseAgent.method(:new)
          Ai::CaseAgent.stub(:new, ->(report, **options) { build.call(report, **options, client: @client, usage: @meter) }, &)
        end

        test "a re-run of the interrupted job resumes its own lease and completes once" do
          stranded = interrupt_first_call("job-1")
          assert_equal "generating", stranded.state

          result = agent(lease_owner: "job-1").call
          assert result[:ok]
          assert_equal "ready", proposal.state
          # One interrupted primary call, then exactly one full generation.
          assert_equal %w(primary primary check), @meter.purposes

          again = agent(lease_owner: "job-1").call
          assert again[:ok]
          assert_equal %w(primary primary check), @meter.purposes, "a finished proposal must not call the provider again"
          assert_equal %w(new resumed), leases
          assert_equal "job-1", Ai::CaseAgent.lease_events(@report, proposal).last.metadata["job_id"]
        end

        test "a fresh lease is never taken by another worker" do
          interrupt_first_call("job-1")
          lease = proposal.updated_at

          [{ lease_owner: "job-2" }, { lease_owner: "job-2", retry_failed: true }, { recover_stale: true }, {}].each do |options|
            result = agent(**options).call
            refute result[:ok]
          end
          assert_equal ["primary"], @meter.purposes
          assert_equal "generating", proposal.state
          assert_equal lease, proposal.updated_at
          assert_equal ["new"], leases
          assert_empty ReportReviewProposalRecovery.run!(organization_id: @organization.id)
          assert_no_enqueued_jobs only: ReportReviewProposalJob
        end

        test "the sweep recovers a stale lease and the recovery generates once" do
          interrupt_first_call("lost-job")

          travel(Ai::CaseAgent::STALE_LEASE + 1.minute) do
            assert_equal [:enqueued], ReportReviewProposalRecovery.run!(organization_id: @organization.id)
            assert_enqueued_with(job: ReportReviewProposalJob, args: [@report.id, { recover_lease: true }])
            with_fake_provider { perform_enqueued_jobs(only: ReportReviewProposalJob) }
          end

          assert_equal "ready", proposal.state
          assert_equal %w(primary primary check), @meter.purposes
          assert_equal %w(new recovered), leases
          assert_empty ReportReviewProposalRecovery.run!(organization_id: @organization.id)
        end

        test "two recoveries queued for one stale lease make one generation" do
          interrupt_first_call("lost-job")

          travel(Ai::CaseAgent::STALE_LEASE + 1.minute) do
            2.times { ReportReviewProposalRecovery.run!(organization_id: @organization.id) }
            assert_enqueued_jobs 2, only: ReportReviewProposalJob
            with_fake_provider { perform_enqueued_jobs(only: ReportReviewProposalJob) }
          end

          assert_equal "ready", proposal.state
          assert_equal %w(primary primary check), @meter.purposes
          assert_equal %w(new recovered), leases
        end

        test "the sweep closes a stale lease whose input changed and keeps it as history" do
          interrupt_first_call("lost-job")
          @report.update!(description: "Kontejner je polomljen kod škole i prevrnut")

          travel(Ai::CaseAgent::STALE_LEASE + 1.minute) do
            assert_equal [:abandoned], ReportReviewProposalRecovery.run!(organization_id: @organization.id)
          end

          assert_no_enqueued_jobs only: ReportReviewProposalJob
          assert_equal "unavailable", proposal.state
          assert_equal "interrupted", proposal.error_code
          assert_equal %w(new abandoned), leases
          assert_equal ["primary"], @meter.purposes
        end

        test "leases older than the recovery window are left for staff" do
          interrupt_first_call("lost-job")

          travel(ReportReviewProposalRecovery::WINDOW + 1.hour) do
            assert_empty ReportReviewProposalRecovery.run!(organization_id: @organization.id)
          end
          assert_equal "generating", proposal.state
          assert_no_enqueued_jobs only: ReportReviewProposalJob
        end

        test "a shutdown between calls leaves the job's lease and its retry resumes it" do
          @client.on_call = -> { WorkerShutdown.request! }
          job = ReportReviewProposalJob.new(@report.id)
          with_fake_provider { job.perform_now }

          assert_equal ["primary"], @meter.purposes, "no provider call may start once the worker is quieting"
          assert_equal "generating", proposal.state
          retry_job = enqueued_jobs.find { |queued| queued["job_class"] == ReportReviewProposalJob.name }
          assert_equal job.job_id, retry_job["job_id"]

          WorkerShutdown.reset!
          @client.on_call = nil
          with_fake_provider { perform_enqueued_jobs(only: ReportReviewProposalJob, at: 1.minute.from_now) }

          assert_equal "ready", proposal.state
          assert_equal %w(primary primary check), @meter.purposes
          assert_equal %w(new resumed), leases
        end

        test "a generation that keeps being interrupted is closed instead of paid for again" do
          interrupt_first_call("job-1")
          Ai::CaseAgent::MAX_RECOVERIES.times { interrupt_first_call("job-1") }

          result = agent(lease_owner: "job-1").call
          refute result[:ok]
          assert_equal "unavailable", proposal.state
          assert_equal "interrupted", proposal.failure_reason
          assert_equal Array.new(Ai::CaseAgent::MAX_RECOVERIES + 1, "primary"), @meter.purposes
          assert_equal ["new"] + Array.new(Ai::CaseAgent::MAX_RECOVERIES, "resumed") + ["exhausted"], leases

          # Staff's explicit retry starts a fresh generation with a fresh budget.
          assert agent(lease_owner: "job-9", retry_failed: true).call[:ok]
          assert_equal "retry", leases.last
        end

        # Worst case per call: GeminiClient applies the timeout to connect and
        # to read; a live lease goes untouched across repair + check.
        test "the stale bound outlasts the longest untouched live lease" do
          worst_call = Ai::CaseAgent::CALL_TIMEOUT + Ai::CaseAgent::CALL_TIMEOUT
          assert_operator Ai::CaseAgent::STALE_LEASE, :>, (2 * worst_call).seconds
        end

        test "an interrupted shadow sweep hands its claim back for the next tick" do
          Setting.put(@organization, ReportShadowSweep::NAMESPACE, ReportShadowSweep::KEY,
                      { "state" => "running", "actor_id" => 0, "pending" => [@report.id], "results" => [] })
          @client.on_call = -> { WorkerShutdown.request! }
          with_fake_provider { assert_nil ReportShadowSweep.new(@organization).call }

          value = Setting.namespace_for(@organization, ReportShadowSweep::NAMESPACE)[ReportShadowSweep::KEY]
          assert_nil value["claim"]
          assert_nil value["claim_at"]
          assert_in_delta 1.minute.from_now, Time.iso8601(value["eligible_at"]), 5
          assert_equal [@report.id], value["pending"], "the report stays at the head of the backlog"
          assert_empty value["results"]
          assert_equal ["primary"], @meter.purposes
          assert_equal "generating", proposal.state
        end
      end
    end
  end
end
