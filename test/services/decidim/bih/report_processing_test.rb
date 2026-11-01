# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require "active_model"
require "active_support/core_ext/object/blank"
require "active_support/testing/time_helpers"
require "active_support/time"
require "decidim/bih/safe_error_metadata"
require_relative "../../../../app/services/decidim/bih/report_processing"
require_relative "../../../../app/services/decidim/bih/report_review_assistant"

module Decidim
  module Bih
    class ReportProcessingTest < Minitest::Test
      include ActiveSupport::Testing::TimeHelpers

      FakeDispatches = Struct.new(:present) do
        def exists? = present
      end

      def run
        @review_first = false
        ReportProcessing.stub(:review_first?, ->(_organization) { @review_first }) { super }
      end

      class FakeReport
        attr_accessor :status, :forwarded_at, :forwarding_error_message, :reviewed_at, :review_state, :report_collection_id, :review_draft, :dispatch_present
        attr_reader :actions, :events, :updates, :column_updates, :clears, :failure_records

        def initialize(status: "primljeno", forwarded_at: nil, forwarding_failed: false)
          @review_draft = {}
          @review_state = "pending"
          @status = status
          @forwarded_at = forwarded_at
          @forwarding_failed = forwarding_failed
          @actions = []
          @events = []
          @updates = []
          @column_updates = []
          @clears = []
          @failure_records = []
          @forwarding_error_message = "Forwarding failed"
        end

        def organization = :test_organization

        def dispatches = FakeDispatches.new(!!dispatch_present)

        def planned? = status == "planirano"

        def duplicate? = false

        def collective? = report_collection_id.present?

        def to_forwarder_hash
          { reference: "BR-2026-1" }
        end

        def update!(attributes)
          @actions << [:update!, attributes]
          @updates << attributes
          attributes.each { |key, value| public_send("#{key}=", value) }
        end

        def update_column(name, value)
          @actions << [:update_column, name, value]
          @column_updates << [name, value]
          public_send("#{name}=", value)
        end

        def record_event!(event_type, **)
          @actions << [:record_event!, event_type]
          @events << { event_type:, ** }
        end

        def clear_forwarding_failure!(**options)
          @actions << [:clear_forwarding_failure!, options]
          @clears << options
        end

        def forwarding_failed_at?
          @forwarding_failed
        end

        def with_lock
          @in_lock = true
          yield
        ensure
          @in_lock = false
        end

        def record_forwarding_failure!(error, code:, source:)
          @failure_records << { error:, code:, source:, in_lock: @in_lock }
          @forwarding_error_message = "Forwarding failed: #{code}"
        end
      end

      class FakeForwarder
        attr_reader :calls, :last_error

        def initialize(return_value:, last_error: nil, raises: nil)
          @return_value = return_value
          @last_error = last_error
          @raises = raises
          @calls = []
        end

        def call(payload)
          @calls << payload
          raise @raises if @raises

          @return_value
        end
      end

      class ErrorWithCode < StandardError
        attr_reader :code

        def initialize(message, code:)
          @code = code
          super(message)
        end
      end

      def test_hold_for_review_records_one_event_and_never_calls_the_forwarder
        forwarder = FakeForwarder.new(return_value: true)
        report = FakeReport.new

        processor_with(forwarder:).send(:hold_for_review, report)

        assert_empty forwarder.calls
        assert_equal "primljeno", report.status
        assert_nil report.forwarded_at
        assert_equal(["forwarding_held_for_review"], report.events.map { |e| e[:event_type] })
      end

      def test_hold_for_review_is_a_no_op_for_forwarded_or_advanced_reports
        forwarder = FakeForwarder.new(return_value: true)
        processor = processor_with(forwarder:)

        forwarded = FakeReport.new(forwarded_at: Time.utc(2026, 9, 7))
        advanced = FakeReport.new(status: "u_obradi")
        processor.send(:hold_for_review, forwarded)
        processor.send(:hold_for_review, advanced)

        assert_empty forwarded.events
        assert_empty advanced.events
      end

      def test_attempt_forward_never_sends_planned_or_collective_cases_individually
        [FakeReport.new(status: "planirano"), FakeReport.new].each_with_index do |report, index|
          report.report_collection_id = 71 if index == 1
          report.reviewed_at = Time.current
          report.review_state = "validated"
          forwarder = FakeForwarder.new(return_value: true)

          assert_nil processor_with(forwarder:).send(:attempt_forward, report, reviewed: true)
          assert_empty forwarder.calls
          assert_empty report.events
          assert_nil report.forwarded_at
        end
      end

      def test_attempt_forward_skips_terminal_reports
        forwarder = FakeForwarder.new(return_value: true)
        report = FakeReport.new(status: "rijeseno")

        assert_nil processor_with(forwarder:).send(:attempt_forward, report)
        assert_empty forwarder.calls
        assert_empty report.events
      end

      def test_legacy_transport_cannot_send_a_human_validated_report_even_with_reviewed_flag
        forwarder = FakeForwarder.new(return_value: true)
        report = FakeReport.new(status: "u_obradi")
        report.reviewed_at = Time.current
        report.review_state = "validated"

        processor_with(forwarder:).send(:attempt_forward, report)
        assert_empty forwarder.calls, "an old automatic job must not send a human-reviewed case"
        processor_with(forwarder:).send(:attempt_forward, report, reviewed: true)

        assert_empty forwarder.calls, "manual approvals must use a durable dispatch"
        assert_equal "u_obradi", report.status
        assert_nil report.forwarded_at
      end

      def test_legacy_transport_cannot_bypass_dispatch_draft_or_ai_review
        [[:dispatch_present, true], [:review_draft, { "values" => {} }]].each do |field, value|
          report = FakeReport.new
          report.public_send("#{field}=", value)
          forwarder = FakeForwarder.new(return_value: true)
          assert_nil processor_with(forwarder:).send(:attempt_forward, report)
          assert_empty forwarder.calls
        end
        @review_first = true
        forwarder = FakeForwarder.new(return_value: true)
        assert_nil processor_with(forwarder:).send(:attempt_forward, FakeReport.new)
        assert_empty forwarder.calls
      end

      def test_attempt_forward_skips_unreviewed_in_progress_reports
        forwarder = FakeForwarder.new(return_value: true)
        report = FakeReport.new(status: "u_obradi")

        processor_with(forwarder:).send(:attempt_forward, report)

        assert_empty forwarder.calls
        assert_nil report.forwarded_at
      end

      def test_attempt_forward_reconciles_already_forwarded_report_without_resending
        forwarded_at = Time.utc(2026, 6, 18, 10, 30)
        forwarder = FakeForwarder.new(return_value: true)
        report = FakeReport.new(forwarded_at:, forwarding_failed: true)

        result = processor_with(forwarder:).send(:attempt_forward, report)

        assert_nil result
        assert_empty forwarder.calls
        assert_equal "proslijedjeno", report.status
        assert_equal [{ status: "proslijedjeno" }], report.updates
        assert_equal "forwarding_reconciled", report.events.first.fetch(:event_type)
        assert_equal "background", report.events.first.fetch(:source)
        assert_equal "system", report.events.first.fetch(:actor_role)
        assert_equal({ status: "proslijedjeno", forwarded_at: }, report.events.first.fetch(:metadata))
        assert_equal [{ reason: "forwarding_reconciled", source: "background" }], report.clears
      end

      def test_attempt_forward_sends_payload_records_forwarded_at_and_status
        forwarder = FakeForwarder.new(return_value: true)
        report = FakeReport.new(forwarding_failed: true)
        timestamp = Time.utc(2026, 6, 18, 12)

        travel_to(timestamp) do
          result = processor_with(forwarder:).send(:attempt_forward, report)

          assert_nil result
        end

        assert_equal [{ reference: "BR-2026-1" }], forwarder.calls
        assert_equal [[:forwarded_at, timestamp]], report.column_updates
        assert_equal [{ status: "proslijedjeno" }], report.updates
        assert_equal "proslijedjeno", report.status
        assert_equal(
          [[:update_column, :forwarded_at, timestamp], [:update!, { status: "proslijedjeno" }]],
          report.actions.first(2)
        )
        assert_equal "forwarding_sent", report.events.first.fetch(:event_type)
        assert_equal({ status: "proslijedjeno", forwarded_at: timestamp }, report.events.first.fetch(:metadata))
        assert_equal [{ reason: "forwarding_sent", source: "background" }], report.clears
      end

      def test_attempt_forward_returns_forwarder_last_error_without_recording_failure
        error = StandardError.new("SMTP unavailable")
        forwarder = FakeForwarder.new(return_value: false, last_error: error)
        report = FakeReport.new

        assert_same error, processor_with(forwarder:).send(:attempt_forward, report)
        assert_equal [{ reference: "BR-2026-1" }], forwarder.calls
        assert_equal "primljeno", report.status
        assert_empty report.events
        assert_empty report.column_updates
      end

      def test_attempt_forward_returns_typed_failure_when_forwarder_has_no_last_error
        forwarder = FakeForwarder.new(return_value: false)
        report = FakeReport.new

        error = processor_with(forwarder:).send(:attempt_forward, report)

        assert_instance_of ReportProcessing::ForwardingFailed, error
        assert_equal "sistem48_forwarding_failed", error.code
        assert_empty report.events
        assert_empty report.column_updates
      end

      def test_forward_records_failure_after_the_lock_then_raises_sanitized_failure
        error = ErrorWithCode.new("SMTP failed for reporter@example.org", code: "smtp_421")
        forwarder = FakeForwarder.new(return_value: false, last_error: error)
        report = FakeReport.new

        raised = assert_raises ReportProcessing::ForwardingFailed do
          processor_with(forwarder:).send(:forward, report)
        end

        assert_equal "smtp_421", raised.code
        assert_equal "Forwarding failed: smtp_421", raised.message
        assert_equal 1, report.failure_records.length
        failure_record = report.failure_records.first
        assert_same error, failure_record.fetch(:error)
        assert_equal "smtp_421", failure_record.fetch(:code)
        assert_equal "background", failure_record.fetch(:source)
        assert_equal false, failure_record.fetch(:in_lock)
      end

      def test_forward_reraises_typed_forwarding_failure_without_recording_duplicate_failure
        typed_error = ReportProcessing::ForwardingFailed.new("typed failure", code: "typed_code")
        forwarder = FakeForwarder.new(return_value: false, raises: typed_error)
        report = FakeReport.new

        raised = assert_raises ReportProcessing::ForwardingFailed do
          processor_with(forwarder:).send(:forward, report)
        end

        assert_same typed_error, raised
        assert_empty report.failure_records
      end

      private

      def processor_with(forwarder: FakeForwarder.new(return_value: true))
        ReportProcessing.new(forwarder:)
      end
    end
  end
end
