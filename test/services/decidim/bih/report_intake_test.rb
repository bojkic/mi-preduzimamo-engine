# frozen_string_literal: true

require "test_helper"
require "active_record"
require "active_support/core_ext/object/blank"
require_relative "../../../../app/services/decidim/bih/report_intake"

module Decidim
  module Bih
    module Goodwill
    end

    class ReportIntakeTest < Minitest::Test
      FakeTransaction = Struct.new(:credited_amount, keyword_init: true)

      class FakeUser
        attr_reader :id

        def initialize(id:)
          @id = id
        end
      end

      class FakePhoto
        def initialize
          @attached = false
        end

        def attach(_attachable)
          @attached = true
        end

        def attached?
          @attached
        end
      end

      class FakeReport
        class << self
          attr_accessor :last_instance, :save_errors

          def reset!
            @last_instance = nil
            @save_errors = []
          end

          def new(**attributes)
            instance = allocate
            instance.send(:initialize, **attributes)
            self.last_instance = instance
            instance
          end
        end

        attr_reader :attributes, :events, :photo, :reference, :reference_assignments, :save_calls
        attr_accessor :id, :status

        def initialize(**attributes)
          @attributes = attributes
          @id = 101
          @reference = "BR-2026-0001"
          @reference_assignments = []
          @status = attributes.fetch(:status)
          @events = []
          @photo = FakePhoto.new
          @save_errors = self.class.save_errors.dup
          @save_calls = 0
        end

        def save!
          @save_calls += 1
          error = @save_errors.shift
          raise error if error

          true
        end

        def reference=(value)
          @reference_assignments << value
          @reference = value
        end

        def record_event!(event_type, **attributes)
          @events << attributes.merge(event_type:)
        end
      end

      class FakeAwardDispatch
        class << self
          attr_accessor :calls, :result, :error

          def reset!
            @calls = []
            @result = nil
            @error = nil
          end
        end

        def self.report_created(report, author:)
          calls << { report:, author: }
          raise error if error

          result
        end
      end

      class FakeJob
        attr_reader :calls

        def initialize(error: nil)
          @error = error
          @calls = []
        end

        def perform_later(report_id, locale:)
          @calls << { report_id:, locale: }
          raise @error if @error

          true
        end

        def name
          "Decidim::Bih::ReportProcessingJob"
        end
      end

      class FakeStaffAlertJob
        def self.perform_later(_report_id) = true
      end

      class FakeLogger
        attr_reader :errors, :warnings

        def initialize
          @errors = []
          @warnings = []
        end

        def error(message)
          @errors << message
        end

        def warn(message)
          @warnings << message
        end
      end

      def setup
        FakeReport.reset!
        FakeAwardDispatch.reset!
      end

      def test_call_persists_report_records_privacy_minimized_events_awards_and_enqueues
        job = FakeJob.new
        FakeAwardDispatch.result = FakeTransaction.new(credited_amount: 20)

        with_dependencies do
          author = Decidim::User.new(id: 42)
          intake = ReportIntake.new(processing_job: job)
          report = intake.call(
            organization: :organization,
            description: "Raw street report",
            address: "Private address 1",
            latitude: "44.756",
            longitude: "19.216",
            reporter_email: "reporter@example.org",
            reporter_phone: "+38765123456",
            public_location_exact: true,
            locale: "bs",
            author:
          )

          assert_same FakeReport.last_instance, report
          assert_equal "primljeno", report.status
          assert_same author, report.attributes.fetch(:author)
          assert_equal true, report.attributes.fetch(:public_location_exact)
          assert_equal 20, intake.awarded_points
          assert_equal [{ report_id: 101, locale: "bs" }], job.calls
          assert_equal(
            [{ report:, author: }],
            FakeAwardDispatch.calls
          )

          created_event = report.events.find { |event| event.fetch(:event_type) == "report_created" }
          assert_equal "public", created_event.fetch(:source)
          assert_equal "citizen", created_event.fetch(:actor_role)
          assert_equal(
            {
              anonymous: false,
              has_photo: false,
              has_location: true,
              public_location_exact: true,
              has_contact: true
            },
            created_event.fetch(:metadata)
          )
          assert_equal false, created_event.fetch(:metadata).values.join(" ").include?("Raw street report")
          assert_equal false, created_event.fetch(:metadata).values.join(" ").include?("reporter@example.org")

          processing_event = report.events.find { |event| event.fetch(:event_type) == "processing_enqueued" }
          assert_equal "background", processing_event.fetch(:source)
          assert_equal "system", processing_event.fetch(:actor_role)
          assert_equal({ locale: "bs" }, processing_event.fetch(:metadata))
        end
      end

      def test_anonymous_call_does_not_award_goodwill_points
        job = FakeJob.new

        with_dependencies do
          intake = ReportIntake.new(processing_job: job)
          report = intake.call(organization: :organization, description: "Anonymous report")

          assert_nil report.attributes.fetch(:author)
          assert_empty FakeAwardDispatch.calls
          assert_nil intake.awarded_points

          created_event = report.events.find { |event| event.fetch(:event_type) == "report_created" }
          assert_nil created_event.fetch(:actor)
          assert_equal "public", created_event.fetch(:actor_role)
        end
      end

      def test_reference_collision_retries_after_clearing_the_generated_reference
        FakeReport.save_errors = [ActiveRecord::RecordNotUnique.new("duplicate")]

        with_dependencies do
          report = ReportIntake.new(processing_job: FakeJob.new)
                               .call(organization: :organization, description: "Retry report")

          assert_equal 2, report.save_calls
          assert_equal [nil], report.reference_assignments
        end
      end

      def test_goodwill_award_failure_is_logged_and_never_blocks_the_report
        FakeAwardDispatch.error = RuntimeError.new("ledger down for reporter@example.org")
        job = FakeJob.new

        with_dependencies do |logger|
          author = Decidim::User.new(id: 42)
          intake = ReportIntake.new(processing_job: job)
          report = intake.call(
            organization: :organization,
            description: "Still saved",
            locale: "sr",
            author:
          )

          assert_same FakeReport.last_instance, report
          assert_nil intake.awarded_points
          assert_equal [{ report_id: 101, locale: "sr" }], job.calls
          assert_match(/\[ReportIntake\] goodwill award failed for report 101: RuntimeError:/, logger.errors.first)
          assert_equal false, logger.errors.first.include?("Still saved")
        end
      end

      def test_processing_enqueue_failure_is_logged_and_swallowed_after_persistence
        job = FakeJob.new(error: RuntimeError.new("queue unavailable"))

        with_dependencies do |logger|
          report = ReportIntake.new(processing_job: job)
                               .call(organization: :organization, description: "Saved before queue failure")

          assert_same FakeReport.last_instance, report
          assert_equal [{ report_id: 101, locale: "sr" }], job.calls
          assert_nil(report.events.find { |event| event.fetch(:event_type) == "processing_enqueued" })
          assert_match(/\[ReportIntake\] processing enqueue failed for report 101: RuntimeError:/, logger.errors.first)
          assert_equal false, logger.errors.first.include?("Saved before queue failure")
        end
      end

      private

      def with_dependencies(&)
        with_constant(Decidim, :User, FakeUser) do
          with_constant(Decidim::Bih, :Report, FakeReport) do
            with_constant(Decidim::Bih::Goodwill, :AwardDispatch, FakeAwardDispatch) do
              with_constant(Decidim::Bih, :ReportStaffAlertJob, FakeStaffAlertJob) { with_rails_logger(&) }
            end
          end
        end
      end

      def with_constant(namespace, name, value)
        existed = namespace.const_defined?(name, false)
        previous = namespace.const_get(name) if existed
        namespace.send(:remove_const, name) if existed
        namespace.const_set(name, value)
        yield
      ensure
        namespace.send(:remove_const, name) if namespace.const_defined?(name, false)
        namespace.const_set(name, previous) if existed
      end

      def with_rails_logger
        logger = FakeLogger.new

        if Object.const_defined?(:Rails)
          return Rails.stub(:logger, logger) { yield logger } if Rails.respond_to?(:logger)

          Rails.define_singleton_method(:logger) { logger }
          return yield logger
        end

        rails = Module.new
        rails.define_singleton_method(:logger) { logger }
        Object.const_set(:Rails, rails)
        yield logger
      ensure
        if defined?(rails) && Object.const_defined?(:Rails) && Rails.equal?(rails)
          Object.send(:remove_const, :Rails)
        elsif Object.const_defined?(:Rails) && Rails.respond_to?(:logger) && Rails.logger.equal?(logger)
          Rails.singleton_class.send(:remove_method, :logger)
        end
      end
    end
  end
end
