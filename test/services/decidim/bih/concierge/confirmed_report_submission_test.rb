# frozen_string_literal: true

require "test_helper"
require "active_record"
require "active_support/core_ext/object/blank"
require "uri"
require "logger"
require "minitest/mock"
require_relative "../../../../../app/services/decidim/bih/concierge/confirmed_report_submission"

module Decidim
  module Bih
    module Concierge
      class ConfirmedReportSubmissionTest < Minitest::Test
        Service = ConfirmedReportSubmission
        Contracts = Dialogue::Contracts

        def test_authority_scope_expiry_and_fields_fail_before_database_access
          context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "a" * 64, capabilities: ["write_report"])
          draft = valid_draft(context)
          assert_raises(Service::InvalidDraft) { Service.new.call(context: context.with(capabilities: []), draft:) }
          assert_raises(Service::InvalidDraft) { Service.new.call(context:, draft: draft.except("disclosure_version")) }
          [
            { "organization_id" => 2 }, { "actor_id" => 3 }, { "conversation_key" => "b" * 64 },
            { "expires_at" => Time.now.to_f - 1 }, { "expires_at" => context.now.to_f + 901 },
            { "description" => "" }, { "description" => "x" * 1001 }, { "address" => nil },
            { "latitude" => 44.0, "longitude" => nil }, { "latitude" => Float::NAN, "longitude" => 19.0 },
            { "possible_duplicates" => "yes" }, { "locale" => "unknown" }, { "code" => "yes" },
            { "public_location_exact" => true }, { "reporter_email" => "not-accepted@example.invalid" }
          ].each do |change|
            assert_raises(ArgumentError, change.keys.join(",")) { Service.new.call(context:, draft: draft.merge(change)) }
          end
        end

        private

        def valid_draft(context)
          {
            "id" => "1" * 48, "code" => "2" * 12, "organization_id" => context.organization_id,
            "actor_id" => context.actor_id, "conversation_key" => context.conversation_key,
            "description" => "Pokvarena rasvjeta kod javnog igrališta.", "address" => "Testna ulica 10",
            "latitude" => nil, "longitude" => nil, "possible_duplicates" => false,
            "locale" => "sr", "expires_at" => context.now.to_f + 900,
            "disclosure_version" => Service::DISCLOSURE_VERSION
          }
        end
      end

      # Opt-in, host-free PostgreSQL proof. Only a freshly created, disposable
      # milica_report_submission_test_* database is accepted; never Rails boot.
      # Uses the actual Intake, DurableEffects and ReportEvent with tiny synthetic
      # report/user tables. Processing/goodwill jobs are captured, never executed.
      class ConfirmedReportSubmissionPostgresTest < ConfirmedReportSubmissionTest
        class Record < ActiveRecord::Base
          self.abstract_class = true

          # These minimal records are temporarily installed at production names.
          def self.compute_type(type_name)
            return type_name.constantize if type_name.start_with?("Decidim::")

            super
          end
        end

        class Organization < Record
          self.table_name = "chat_test_organizations"
        end

        class User < Record
          self.table_name = "chat_test_users"
          include GlobalID::Identification
        end

        class Report < Record
          self.table_name = "chat_test_reports"
          belongs_to :organization, class_name: "Decidim::Organization", foreign_key: :decidim_organization_id
          belongs_to :author, class_name: "Decidim::User", foreign_key: :decidim_user_id, optional: true
          has_many :events, class_name: "Decidim::Bih::ReportEvent", foreign_key: :decidim_bih_report_id
          validates :description, presence: true
          before_validation do
            self.reference ||= "BR-2026-#{format("%04d", (self.class.maximum(:id) || 0) + 1)}"
          end

          def photo
            Struct.new(:attached?).new(false)
          end

          def record_event!(event_type, **attributes)
            events.create!(**attributes, event_type:, organization:)
          end
        end

        def setup
          url = ENV.fetch("MILICA_REPORT_SUBMISSION_TEST_DATABASE_URL", "")
          skip "Set an isolated MILICA_REPORT_SUBMISSION_TEST_DATABASE_URL for PostgreSQL proofs" if url.empty?
          parsed = URI.parse(url)
          raise "Disposable report-test database required" unless
            parsed.scheme == "postgresql" && parsed.path.match?(%r{\A/milica_report_submission_test_[a-z0-9_]+\z})
          raise "Do not run this isolated proof inside Rails" if defined?(Rails::Application) && Rails.respond_to?(:application) && Rails.application.is_a?(Rails::Application)

          Record.establish_connection(url)
          @replaced = []
          install_isolated_logger
          replace_constant(Decidim, :ApplicationRecord, Record)
          replace_constant(Decidim, :Organization, Organization)
          replace_constant(Decidim, :User, User)
          replace_constant(Decidim::Bih, :Report, Report)
          replace_constant(Decidim::Bih, :ReportEvent, nil)
          load File.expand_path("../../../../../app/models/decidim/bih/report_event.rb", __dir__)
          # Report survives between examples while ReportEvent is reloaded.
          # Rebuild its reflection so events use this example's model class.
          Report.has_many :events, class_name: "Decidim::Bih::ReportEvent", foreign_key: :decidim_bih_report_id
          install_job(Decidim::Bih, :ReportProcessingJob)
          install_job(Decidim::Bih, :ReportStaffAlertJob)
          install_job(Decidim::Bih::Goodwill, :GoodwillAwardJob)
          # The new report_created outbox is real persistence too. Keep its
          # worker isolated from the receipt transport jobs; it never executes.
          [:CorrectionIntent, :SourceCreditCorrection, :ReportEntitlement].each do |name|
            replace_constant(Decidim::Bih::Goodwill, name, nil)
          end
          load File.expand_path("../../../../../app/models/decidim/bih/goodwill/correction_intent.rb", __dir__)
          load File.expand_path("../../../../../app/services/decidim/bih/goodwill/source_credit_correction.rb", __dir__)
          load File.expand_path("../../../../../app/services/decidim/bih/goodwill/report_entitlement.rb", __dir__)
          rules = Class.new { def self.points_for_action(_action, organization:) = 20 }
          replace_constant(Decidim::Bih::Goodwill, :EarningRules, rules)
          correction_job = Class.new
          replace_constant(Decidim::Bih::Goodwill, :SourceCreditCorrectionJob, correction_job)
          @correction_deliveries = []
          deliveries = @correction_deliveries
          correction_job.define_singleton_method(:perform_later) do |id|
            deliveries << [id, Report.connection.transaction_open?, Report.count,
                           Decidim::Bih::ReportEvent.where(event_type: Service::CONFIRMED_EVENT).count]
          end
          create_tables
          @organization = Organization.create!
          @context = Contracts::TrustedContext.new(organization_id: @organization.id, conversation_key: "a" * 64, capabilities: ["write_report"])
          @draft = valid_draft(@context)
          @deliveries = []
          @service = Service.new
          @previous_global_id_app = GlobalID.app
          GlobalID.app = "report-submission-test"
        end

        def teardown
          return unless @replaced

          @replaced.reverse_each do |namespace, name, previous, existed|
            namespace.send(:remove_const, name) if namespace.const_defined?(name, false)
            namespace.const_set(name, previous) if existed
          end
          Rails.singleton_class.send(:remove_method, :logger) unless @previous_logger
          Object.send(:remove_const, :Rails) if @created_rails_module
          GlobalID.instance_variable_set(:@app, @previous_global_id_app)
          Record.connection_pool.disconnect!
        end

        def test_report_receipt_and_jobs_commit_before_replay_and_identical_retry_is_read_only
          previous_timeout = Record.connection.select_value("SHOW statement_timeout")
          previous_lock_timeout = Record.connection.select_value("SHOW lock_timeout")
          receipt = @service.call(context: @context, draft: @draft)
          assert_equal 1, Report.count
          assert_equal %w(reference replayed), receipt.to_h.keys.map(&:to_s)
          assert_equal false, receipt.replayed
          report = Report.first
          assert_equal report.reference, receipt.reference
          assert_equal true, report.anonymous
          assert_equal false, report.public_location_exact
          assert_nil report.reporter_email
          assert_nil report.reporter_phone
          assert_nil report.author
          assert_equal [["Decidim::Bih::ReportStaffAlertJob", false, 1, 1], ["Decidim::Bih::ReportProcessingJob", false, 1, 1]], @deliveries
          replay = @service.call(context: @context, draft: @draft.merge("state_version" => 42))
          assert_equal receipt.reference, replay.reference
          assert_equal true, replay.replayed
          assert_equal previous_timeout, Record.connection.select_value("SHOW statement_timeout")
          assert_equal previous_lock_timeout, Record.connection.select_value("SHOW lock_timeout")
          assert_equal 2, @deliveries.size
          intent = Decidim::Bih::Goodwill::CorrectionIntent.first
          assert_equal 1, Decidim::Bih::Goodwill::CorrectionIntent.count
          assert_equal [[intent.id, false, 1, 1]], @correction_deliveries
          assert_equal 1, Report.count
          metadata = Decidim::Bih::ReportEvent.where(event_type: Service::CONFIRMED_EVENT).first.metadata.to_json
          [@draft["description"], @draft["address"], @draft["code"], @draft["conversation_key"]].each { |secret| refute_includes metadata, secret }
          assert_raises(Service::InvalidDraft) { @service.call(context: @context, draft: @draft.merge("description" => "Drugi problem.")) }
          assert_equal 1, Report.count
        end

        def test_required_receipt_failure_rolls_back_report_and_never_enqueues
          create = Decidim::Bih::ReportEvent.method(:create!)
          failure = lambda do |**attributes|
            raise ActiveRecord::StatementInvalid, "synthetic missing receipt" if attributes[:event_type] == Service::CONFIRMED_EVENT

            create.call(**attributes)
          end
          Decidim::Bih::ReportEvent.stub(:create!, failure) do
            assert_raises(ActiveRecord::StatementInvalid) { @service.call(context: @context, draft: @draft) }
          end
          assert_equal 0, Report.count
          assert_equal 0, Decidim::Bih::ReportEvent.count
          assert_equal 0, Decidim::Bih::Goodwill::CorrectionIntent.count
          assert_empty @correction_deliveries
          assert_empty @deliveries
          @service.call(context: @context, draft: @draft)
          assert_equal 1, Report.count
        end

        def test_unexpected_job_rolls_back_the_report_and_receipt_without_dispatch
          install_job(Decidim::Bih, :KomsilukPostNotificationJob)
          intake = Service::Intake.new
          original = intake.method(:call)
          intake.define_singleton_method(:call) do |**attributes|
            report = original.call(**attributes)
            Decidim::Bih::DurableEffects.enqueue(Decidim::Bih::KomsilukPostNotificationJob, report.id)
            report
          end
          Service::Intake.stub(:new, -> { intake }) do
            assert_raises(Service::Unavailable) { @service.call(context: @context, draft: @draft) }
          end
          assert_equal 0, Report.count
          assert_equal 0, Decidim::Bih::ReportEvent.count
          assert_empty @deliveries
        end

        def test_queue_failure_retries_durable_effect_without_recreating_report
          @queue_failure = true
          assert_raises(RuntimeError) { @service.call(context: @context, draft: @draft) }
          assert_equal 1, Report.count
          assert_equal 1, Decidim::Bih::ReportEvent.where(event_type: Service::CONFIRMED_EVENT).count
          assert_equal 0, Decidim::Bih::ReportEvent.where(event_type: Service::DISPATCHED_EVENT).count
          @queue_failure = false
          receipt = @service.call(context: @context, draft: @draft)
          assert_equal Report.first.reference, receipt.reference
          assert_equal true, receipt.replayed
          assert_equal 1, Report.count
          assert_equal 1, Decidim::Bih::ReportEvent.where(event_type: Service::DISPATCHED_EVENT).count
          assert_equal ["Decidim::Bih::ReportStaffAlertJob", "Decidim::Bih::ReportStaffAlertJob", "Decidim::Bih::ReportProcessingJob"], @deliveries.map(&:first)
          assert(@deliveries.all? { |delivery| delivery[1] == false })
        end

        def test_legacy_preview_replay_recovers_existing_receipt_but_never_creates
          legacy = @draft.except("disclosure_version")
          assert_nil @service.replay(context: @context, draft: legacy)
          assert_equal 0, Report.count
          assert_empty @deliveries
          assert_raises(Service::InvalidDraft) { @service.call(context: @context, draft: legacy) }

          original = @service.call(context: @context, draft: @draft)
          replay = @service.replay(context: @context, draft: legacy)
          assert_equal original.reference, replay.reference
          assert_equal true, replay.replayed
          assert_equal 1, Report.count
          assert_equal 2, @deliveries.size
        end

        def test_signed_in_author_award_is_preserved_after_commit_and_cross_tenant_actor_is_rejected
          author = User.create!(decidim_organization_id: @organization.id)
          context = @context.with(actor_id: author.id)
          draft = valid_draft(context)
          assert_raises(Service::InvalidDraft) { @service.call(context:, draft:) }
          other_context = context.with(organization_id: @organization.id + 1)
          assert_raises(Service::InvalidDraft) { @service.call(context: other_context, draft: valid_draft(other_context), author:) }
          @service.call(context:, draft:, author:)
          assert_equal author.id, Report.first.decidim_user_id
          assert_equal ["Decidim::Bih::Goodwill::GoodwillAwardJob", "Decidim::Bih::ReportStaffAlertJob", "Decidim::Bih::ReportProcessingJob"], @deliveries.map(&:first)
          assert(@deliveries.all? { |delivery| delivery[1..] == [false, 1, 1] })
          event = Decidim::Bih::ReportEvent.where(event_type: Service::CONFIRMED_EVENT).first
          assert_includes event.metadata["effects_json"], "bih_report:#{Report.first.id}"
        end

        def test_savepoint_recovers_real_unique_violation_inside_receipt_transaction
          original = Report.create!(organization: @organization, description: "Existing report")
          report = Report.new(organization: @organization, description: "New report", reference: original.reference)
          Report.transaction do
            Service::Intake.new.send(:save_with_reference_retry, report)
            assert_equal 2, Report.count
          end
          refute_equal original.reference, report.reference
          assert_equal 2, Report.count
        end

        def test_busy_receipt_lock_and_outer_transaction_cannot_submit
          digest = Digest::SHA256.hexdigest(JSON.generate(@draft.values_at("organization_id", "actor_id", "conversation_key", "id")))
          lock_id = [digest[0, 16]].pack("H*").unpack1("q>")
          Record.connection_pool.with_connection do |connection|
            connection.execute("SELECT pg_advisory_lock(#{lock_id})")
            error = Thread.new do
              @service.call(context: @context, draft: @draft)
            rescue StandardError => e
              e
            end.value
            assert_instance_of Service::Unavailable, error
          ensure
            connection.select_value("SELECT pg_advisory_unlock(#{lock_id})")
          end
          Report.transaction { assert_raises(Service::Unavailable) { @service.call(context: @context, draft: @draft) } }
          assert_equal 0, Report.count
          assert_empty @deliveries
        end

        private

        def install_isolated_logger
          @created_rails_module = !Object.const_defined?(:Rails)
          Object.const_set(:Rails, Module.new) if @created_rails_module
          @previous_logger = Rails.method(:logger) if Rails.respond_to?(:logger)
          Rails.define_singleton_method(:logger) { Logger.new(File::NULL) } unless @previous_logger
        end

        def replace_constant(namespace, name, value)
          existed = namespace.const_defined?(name, false)
          previous = namespace.const_get(name) if existed
          @replaced << [namespace, name, previous, existed]
          namespace.send(:remove_const, name) if existed
          namespace.const_set(name, value) unless value.nil?
        end

        def install_job(namespace, name)
          job = Class.new
          replace_constant(namespace, name, job)
          owner = self
          job.define_singleton_method(:perform_later) do |*|
            deliveries = owner.instance_variable_get(:@deliveries)
            deliveries << [self.name, Report.connection.transaction_open?, Report.count,
                           Decidim::Bih::ReportEvent.where(event_type: Service::CONFIRMED_EVENT).count]
            raise "synthetic queue failure" if owner.instance_variable_get(:@queue_failure)

            true
          end
        end

        def create_tables
          connection = Record.connection
          %w(decidim_bih_goodwill_correction_intents decidim_bih_report_events chat_test_reports chat_test_users chat_test_organizations).each do |table|
            connection.drop_table(table, if_exists: true)
          end
          connection.create_table(:chat_test_organizations)
          connection.create_table(:chat_test_users) { |table| table.bigint :decidim_organization_id, null: false }
          connection.create_table(:chat_test_reports) do |table|
            table.bigint :decidim_organization_id, null: false
            table.bigint :decidim_user_id
            table.bigint :duplicate_of_report_id
            table.string :reference, null: false
            table.text :description, null: false
            [:address, :status, :reporter_email, :reporter_phone].each { |column| table.string column }
            [:latitude, :longitude].each { |column| table.float column }
            [:anonymous, :public_location_exact].each { |column| table.boolean column }
            table.index [:decidim_organization_id, :reference], unique: true
          end
          connection.create_table(:decidim_bih_report_events) do |table|
            table.bigint :decidim_bih_report_id, null: false
            table.bigint :decidim_organization_id, null: false
            table.bigint :decidim_user_id
            [:event_type, :source, :actor_role].each { |column| table.string column }
            table.datetime :occurred_at, null: false
            table.jsonb :metadata, default: {}, null: false
          end
          connection.create_table(:decidim_bih_goodwill_correction_intents) do |table|
            table.bigint :report_id, null: false
            table.bigint :report_event_id, null: false
            table.string :decision_version, null: false
            table.integer :target_amount, null: false
            table.datetime :processed_at
            table.timestamps
            table.index :report_event_id, unique: true
          end
          [Organization, User, Report, Decidim::Bih::ReportEvent, Decidim::Bih::Goodwill::CorrectionIntent].each(&:reset_column_information)
        end
      end
    end
  end
end
