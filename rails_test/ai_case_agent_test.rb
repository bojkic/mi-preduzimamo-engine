# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class AiCaseAgentTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper
        class Client
          attr_reader :requests
          attr_accessor :on_call

          def initialize(value)
            @value = value
            @requests = []
          end

          def generate_content(**args)
            @requests << args
            on_call&.call(@requests.length)
            @value.deep_dup
          end
        end

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
          @context = Ai::ReportReviewContext.new(@report)
        end
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
        test "engine default holds intake even with the agent off" do
          assert Decidim::Bih.report_review_first
          report = Report.create!(organization: @organization, description: "Fresh unclassified report")
          assert_no_difference "ActionMailer::Base.deliveries.size" do
            ReportProcessing.new.call(report:)
          end
          assert_nil report.reload.category
          assert_nil report.severity
          assert_nil report.forwarded_at
          assert_empty report.review_proposals
          assert report.events.exists?(event_type: "forwarding_held_for_review")
        end

        test "oversize creates a bounded case-agent marker without model calls" do
          @report.update!(description: "Private evidence " * 4000)
          meter = Meter.new
          first = Ai::CaseAgent.new(@report, client: Client.new(valid), usage: meter).call[:proposal]
          second = Ai::CaseAgent.new(@report, client: Client.new(valid), usage: meter).call[:proposal]
          assert_equal first.id, second.id
          assert_equal "context_too_large", first.error_code
          assert_equal "unavailable", first.state
          assert_nil first.proposal_ciphertext
          assert_empty meter.purposes
          refute first.current?
        end

        test "ready proposal retains separate boolean agreement signals" do
          client = Client.new(valid)
          meter = Meter.new
          result = Ai::CaseAgent.new(@report, client:, usage: meter).call
          assert result[:ok]
          assert result[:proposal].current?
          assert_equal({ "validators" => true, "agreement" => true, "deterministic" => true }, result[:proposal].proposal["signals"])
          assert_equal %w(primary check), meter.purposes
        end
        test "no date or unknown identifier may enter a decision" do
          [:unknown_recipient, :unknown_obligation, :date].each do |kind|
            value = valid
            case kind
            when :unknown_recipient then value["routing"]["recipient_key"] = "invented"
            when :unknown_obligation then value["obligation_updates"] = [{ "obligation_id" => 9_999, "new_kind" => "", "action" => "fulfil" }]
            when :date then value["due_at"] = "2026-10-10"
            end
            assert_raises(Ai::ProposalValidators::Invalid) { Ai::ProposalValidators.new.validate!(value, @context) }
          end
        end
        test "a precise container never requires a photo" do
          value = valid
          value["missing_fields"] = [{ "field" => "photo_helpful", "required" => true, "why_quote" => "Kontejner je polomljen" }]
          error = assert_raises(Ai::ProposalValidators::Invalid) { Ai::ProposalValidators.new.validate!(value, @context) }
          assert_equal "question_mismatch", error.reason
        end
        test "model-only hazard stays in the shadow proposal and opens no staff task" do
          value = valid
          value["assessment"].merge!("hazard_signal" => true, "hazard_quote" => "Kontejner je polomljen")
          value["proposed_action"] = "resolve"
          result = Ai::CaseAgent.new(@report, client: Client.new(value), usage: Meter.new).call
          assert result[:ok]
          refute result[:signals][:deterministic]
          refute ReportObligation.exists?(report: @report)
          assert_equal "primljeno", @report.reload.status
        end
        test "transport failure is retried once by the shadow sweep and then recorded" do
          Setting.put(@organization, "report_review", "case_agent", "shadow")
          other = Report.create!(organization: @organization, description: "Rupa na putu kod škole", address: "Ulica 2", category: "putevi")
          Setting.put(@organization, ReportShadowSweep::NAMESPACE, ReportShadowSweep::KEY,
                      { "state" => "running", "actor_id" => 0, "pending" => [@report.id, other.id], "results" => [] })
          calls = []
          stub = lambda do |report, retry_failed: false, shadow_only: false|
            raise "sweep must ask for shadow only" unless shadow_only

            calls << [report.id, retry_failed]
            proposal = report.review_proposals.find_or_initialize_by(input_digest: "d", prompt_version: Ai::CaseAgent::PROMPT_VERSION)
            proposal.update!(state: "unavailable", failure_reason: "unavailable", error_code: "invalid_response")
            proposal
          end
          ReportReviewAssistant.stub(:eligible?, true) do
            assistant = Struct.new(:fn) { def call(report, **opts) = fn.call(report, **opts) }.new(stub)
            ReportReviewAssistant.stub(:new, ->(*) { assistant }) do
              4.times { ReportShadowSweep.new(@organization).call }
            end
          end
          value = Setting.namespace_for(@organization, ReportShadowSweep::NAMESPACE)[ReportShadowSweep::KEY]
          assert_equal [[@report.id, false], [other.id, false], [@report.id, true], [other.id, true]], calls
          assert_equal "complete", value["state"]
          assert_equal([@report.id, other.id], value["results"].map { |row| row["report_id"] })
        end
        test "facts are literal, observations are not a quotation escape hatch" do
          value = valid
          value["facts"].first["text"] = "Invented condition"
          error = assert_raises(Ai::ProposalValidators::Invalid) { Ai::ProposalValidators.new.validate!(value, @context) }
          assert_equal "fact_not_quoted", error.reason
        end
        test "wait is explicit and cannot carry an outgoing side effect" do
          value = valid.merge("proposed_action" => "wait")
          assert_equal "wait", Ai::ProposalValidators.new.validate!(value, @context)["proposed_action"]
          value["city_message"]["text"] = "Kontejner je polomljen"
          error = assert_raises(Ai::ProposalValidators::Invalid) { Ai::ProposalValidators.new.validate!(value, @context) }
          assert_equal "wait_has_effects", error.reason
        end
        test "municipal file references survive redaction but phone numbers do not" do
          context = Ai::ReportReviewContext.new(@report)
          text = context.redact("Broj 02/13-893/26, telefon +38766123456")
          assert_includes text, "02/13-893/26"
          refute_includes text, "+38766123456"
        end
        test "invalid quote diagnostics identify a field without retaining its content" do
          value = valid
          value["facts"].first["text"] = "PRIVATE INVALID TEXT"
          error = assert_raises(Ai::ProposalValidators::Invalid) { Ai::ProposalValidators.new.validate!(value, @context) }
          assert_equal "fact_not_quoted: facts[0]", error.diagnostic
          refute_includes error.diagnostic, "PRIVATE"
        end
        test "contact and plate redaction protects the context" do
          @report.update!(description: "Kontejner A12-E-345 kontakt +38766123456 mail citizen@example.org", address: "Ulica 1")
          context = Ai::ReportReviewContext.new(@report)
          refute_includes context.data.to_json, "A12-E-345"
          refute_includes context.data.to_json, "+38766123456"
          refute_includes context.data.to_json, "citizen@example.org"
          refute_includes context.data.to_json, @report.status_token
        end
        test "lost primary lease cannot write diagnostics or start repair" do
          value = valid
          value["facts"].first["text"] = "Invalid response"
          client = Client.new(value)
          client.on_call = ->(_) { @report.review_proposals.last.update!(updated_at: 1.minute.from_now) }
          meter = Meter.new
          result = nil
          assert_no_enqueued_jobs do
            result = Ai::CaseAgent.new(@report, client:, usage: meter).call
          end
          assert_equal "lease_lost", result[:reason]
          assert_equal ["primary"], meter.purposes
          assert_equal "generating", result[:proposal].state
          refute result[:proposal].repair_attempted
          assert_nil result[:proposal].failure_reason
        end
        test "lost repair lease cannot mark new claim unavailable or alert staff" do
          value = valid
          value["facts"].first["text"] = "Invalid response"
          client = Client.new(value)
          client.on_call = lambda do |count|
            @report.review_proposals.last.update!(updated_at: 1.minute.from_now, repair_attempted: false, failure_reason: nil) if count == 2
          end
          meter = Meter.new
          result = nil
          assert_no_enqueued_jobs do
            result = Ai::CaseAgent.new(@report, client:, usage: meter).call
          end
          refute result[:ok]
          assert_equal %w(primary repair), meter.purposes
          assert_equal "generating", result[:proposal].state
          refute result[:proposal].repair_attempted
          assert_nil result[:proposal].failure_reason
          assert_nil result[:proposal].error_code
        end
        test "exactly one repair receives reason without invalid model output" do
          value = valid
          value["facts"].first["text"] = "SENSITIVE INVALID OUTPUT"
          client = Client.new(value)
          meter = Meter.new
          result = nil
          assert_no_enqueued_jobs { result = Ai::CaseAgent.new(@report, client:, usage: meter).call }
          refute result[:ok]
          assert_equal "unavailable", result[:proposal].state
          assert result[:proposal].repair_attempted
          assert_equal "fact_not_quoted", result[:proposal].failure_reason
          assert_equal %w(primary repair), meter.purposes
          refute_includes client.requests.last.to_json, "SENSITIVE INVALID OUTPUT"
          assert_empty result[:proposal].proposal
        end
      end
    end
  end
end
