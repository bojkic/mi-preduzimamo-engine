# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Tasks 3.3 and 3.5 — retention, authorized lookup, and a report that
      # reports rather than repairs.
      class MessagingReconciliationTest < ActiveSupport::TestCase
        ATTEMPT = Decidim::Bih::Messaging::Attempt
        INTENT = Decidim::Bih::Messaging::Intent
        SUPPRESSION = Decidim::Bih::Messaging::Suppression
        STORE = Decidim::Bih::Messaging::TransportSuppression
        KEY = Decidim::Bih::Messaging::SuppressionKey
        RECONCILIATION = Decidim::Bih::Messaging::Reconciliation
        LOOKUP = Decidim::Bih::Messaging::RecipientLookup
        SWEEP = Decidim::Bih::Privacy::RetentionSweep
        PHONE = "+38765111001"

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def build_intent(user: @citizen, message_class: "report.author_external_copy", created_at: nil)
          intent = INTENT.create!(organization: @organization, user:, message_class:,
                                  recipient_kind: "account", correlation_key: "c-#{SecureRandom.hex(4)}",
                                  deduplication_scope: "#{message_class}:external_copy",
                                  policy_version: "v", eligibility_version: "v", mode: "shadow", status: "recorded")
          intent.update_columns(created_at:, updated_at: created_at) if created_at # rubocop:disable Rails/SkipsModelValidations
          intent
        end

        def build_attempt(intent: nil, status: "accepted", reason: nil, created_at: nil, claimed_at: Time.current)
          intent ||= build_intent
          attempt = intent.attempts.create!(channel_group: "external_copy", channel: "viber", status:, reason:,
                                            claimed_at:, destination_kind: "phone",
                                            destination_digest: KEY.digest(kind: :phone, value: PHONE))
          attempt.update_columns(created_at:, updated_at: created_at) if created_at # rubocop:disable Rails/SkipsModelValidations
          attempt
        end

        def suppression(reason: "provider_opt_out", value: PHONE)
          STORE.ingest!(organization: @organization, provider: "infobip", channel: "viber",
                        destination: { kind: :phone, value: }, reason:, source: "provider_webhook",
                        event_ref: "evt-#{SecureRandom.hex(4)}")
        end

        # ---- Task 3.3: retention ---------------------------------------------

        test "the attempt ledger ages out by when the leg was recorded" do
          build_attempt(created_at: 4.years.ago)
          build_attempt(created_at: 1.day.ago)

          result = SWEEP.call(organization: @organization, messaging_attempt_before: 3.years.ago, dry_run: false)

          assert_equal 1, result.counts[:messaging_attempts]
          assert_equal 1, ATTEMPT.count
        end

        test "a dry run counts the same rows and deletes none of them" do
          build_attempt(created_at: 4.years.ago)

          result = SWEEP.call(organization: @organization, messaging_attempt_before: 3.years.ago, dry_run: true)

          assert_equal 1, result.counts[:messaging_attempts]
          assert_equal 1, ATTEMPT.count
        end

        test "an ACTIVE suppression outlives the attempt ledger, at any age" do
          active = suppression
          active.update_columns(suppressed_at: 4.years.ago, occurred_at: 4.years.ago, created_at: 4.years.ago) # rubocop:disable Rails/SkipsModelValidations
          build_attempt(created_at: 4.years.ago)

          SWEEP.call(organization: @organization, messaging_attempt_before: 3.years.ago,
                     messaging_suppression_before: 3.years.ago, dry_run: false)

          assert_equal 0, ATTEMPT.count
          assert SUPPRESSION.exists?(active.id),
                 "deleting an active refusal would silently re-enable sending to a destination that refused"
        end

        test "a resolved suppression does age out, by when it was resolved" do
          lifted = suppression
          STORE.reactivate!(lifted, evidence: "operator_case:1")
          lifted.update_columns(reactivated_at: 4.years.ago) # rubocop:disable Rails/SkipsModelValidations

          result = SWEEP.call(organization: @organization, messaging_suppression_before: 3.years.ago, dry_run: false)

          assert_equal 1, result.counts[:messaging_suppressions]
          assert_not SUPPRESSION.exists?(lifted.id)
        end

        test "the retention contract names both new tables and excludes the destination digest" do
          buckets = Decidim::Bih::PrivacyAuditContracts::RETENTION_BUCKETS
          attempts = buckets.find { |bucket| bucket[:id] == "messaging_attempts" }
          suppressions = buckets.find { |bucket| bucket[:id] == "messaging_suppressions" }

          assert_includes attempts[:storage], "decidim_bih_messaging_attempts"
          assert_includes attempts[:excludes_from_run_history], "destination_digest"
          assert_includes suppressions[:storage], "decidim_bih_messaging_suppressions"
          assert_includes suppressions[:excludes_from_run_history], "destination_digest"
        end

        # ---- Task 3.3: deletion redacts, it does not erase --------------------

        test "an account deletion redacts the destination and keeps the operational event" do
          attempt = build_attempt

          @citizen.update!(deleted_at: Time.current)

          attempt.reload
          assert attempt.persisted?, "an immutable operational event is redacted, not erased"
          assert_equal "redacted", attempt.destination_kind
          assert_nil attempt.destination_digest, "a digest is still a stable pointer at a person"
          assert_equal "accepted", attempt.status, "what happened is still what happened"
        end

        # ---- Task 3.3: authorized lookup --------------------------------------

        test "the operator lookup refuses an operator without the case permission" do
          attempt = build_attempt
          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)

          assert_raises(Decidim::ActionForbidden) { LOOKUP.for_operator(attempt:, operator: stranger) }
        end

        test "the operator lookup answers a permitted operator, and never with a destination" do
          attempt = build_attempt(reason: "smtp_accepted")
          admin = FactoryBot.create(:user, :confirmed, organization: @organization, admin: true)

          result = LOOKUP.for_operator(attempt:, operator: admin)

          assert_equal LOOKUP::FIELDS.sort, result.keys.sort
          assert_equal "viber", result[:channel]
          assert_equal "accepted", result[:outcome]
          refute_match(/@|\+387|[0-9a-f]{64}/, result.to_json)
        end

        test "an operator from another tenant is refused" do
          attempt = build_attempt
          outsider = FactoryBot.create(:user, :confirmed, organization: create_organization, admin: true)

          assert_raises(Decidim::ActionForbidden) { LOOKUP.for_operator(attempt:, operator: outsider) }
        end

        # ---- Task 3.5: the report reports -------------------------------------

        test "reconciliation never resets an uncertain attempt to pending" do
          attempt = build_attempt(status: "uncertain", reason: "worker_interrupted")

          RECONCILIATION.report(organization: @organization, since: 1.day.ago)

          assert_equal "uncertain", attempt.reload.status
          assert_equal "worker_interrupted", attempt.reason
        end

        test "the report is aggregate and carries no identifier of any kind" do
          build_attempt
          suppression

          json = RECONCILIATION.report(organization: @organization, since: 1.day.ago).to_json

          refute_match(/@example|\+387|[0-9a-f]{64}/, json)
        end

        test "the report names stuck, unknown, expired and skipped separately, with reasons" do
          build_attempt(status: "claimed", claimed_at: 2.hours.ago)
          build_attempt(status: "uncertain", reason: "worker_interrupted")
          build_attempt(status: "expired", reason: "expired")
          build_attempt(status: "skipped", reason: "ineligible")

          summary = RECONCILIATION.report(organization: @organization, since: 1.day.ago)

          assert_equal 1, summary[:stuck]
          assert_equal 1, summary[:unknown]
          assert_equal 1, summary[:expired]
          assert_equal 1, summary[:skipped]
          assert_equal 1, summary[:reasons]["ineligible"]
        end

        test "a correlation gap is counted, and an unenrolled class is listed as uncovered rather than idle" do
          build_attempt # report.author_external_copy, with a real leg
          build_intent(message_class: "operator.direct_message") # an intent with no leg at all

          summary = RECONCILIATION.report(organization: @organization, since: 1.day.ago)

          assert_equal 1, summary[:intents_without_attempts], "the gap is reported, never repaired"
          assert_not_includes summary[:classes_without_attempts], "report.author_external_copy",
                              "a class with a real leg is covered"
          assert_includes summary[:classes_without_attempts], "city.service_alert_viber",
                          "a class with no attempts is UNCOVERED, not idle: it keeps its own evidence"
          assert_includes summary[:classes_without_attempts], "operator.direct_message",
                          "an intent with no leg does not make its class covered"
        end

        test "the report reads another tenant's rows not at all" do
          other = create_organization
          INTENT.create!(organization: other, user: FactoryBot.create(:user, :confirmed, organization: other),
                         message_class: "report.author_external_copy", recipient_kind: "account",
                         correlation_key: "x", deduplication_scope: "s", policy_version: "v",
                         eligibility_version: "v", mode: "shadow", status: "recorded")

          assert_equal 0, RECONCILIATION.report(organization: @organization, since: 1.day.ago)[:intents]
        end

        # ---- Task 3.5: the provider report queue is not drained ---------------

        test "the delivery-report path asks per message id and never for a batch" do
          calls = []
          client = Object.new
          client.define_singleton_method(:message_delivery_reports) do |message_id:|
            calls << message_id
            { "results" => [] }
          end
          notification = Decidim::Bih::AccountNotification.new(
            organization: @organization, user: @citizen, topic: "report_updates",
            deduplication_digest: SecureRandom.hex(16), expires_at: 1.day.from_now,
            status: "accepted", provider_message_ids: %w(m1 m2)
          )
          notification.payload = { "text" => "x", "channels" => ["viber"] }
          notification.save!

          Decidim::Bih::Infobip::Client.stub(:new, client) do
            Decidim::Bih::AccountNotifications.reconcile!(notification)
          end

          assert_equal %w(m1 m2), calls, "one request per known id; a bulk drain would starve this caller"
        end

        test "the installed rake tasks are read-only about history" do
          require "rake"
          Rails.application.load_tasks unless Rake::Task.task_defined?("decidim_bih:messaging:report")

          assert Rake::Task.task_defined?("decidim_bih:messaging:report")
          assert Rake::Task.task_defined?("decidim_bih:messaging:reactivate_suppression")
          body = Decidim::Bih::Engine.root.join("lib", "tasks", "decidim_bih_messaging_history.rake").read
          refute_match(/perform_later|perform_now|deliver_now|send_phone_message|update_all/, body)
        end
      end
    end
  end
end
