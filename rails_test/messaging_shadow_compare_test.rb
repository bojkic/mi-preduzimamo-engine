# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 1.6: compare actual decisions from the same frozen inputs, in both
      # directions, and record the minimum dispatch evidence a pilot needs
      # before anything is allowed to send through it.
      class MessagingShadowCompareTest < ActiveSupport::TestCase
        def compare_class = Decidim::Bih::Messaging::ShadowCompare

        def evidence = Decidim::Bih::Messaging::DispatchEvidence

        def context_class = Decidim::Bih::Messaging::RecipientContext

        setup do
          # Both decisions compare the same instant as well as the same inputs.
          # Otherwise identical TTLs can straddle a wall-clock second.
          freeze_time
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @digest = Digest::SHA256.hexdigest("+38765000000")
        end

        # ---- comparison ------------------------------------------------------

        test "compatibility mode over the same inputs shows no difference in either direction" do
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic: :report_updates, channel: :viber, enabled: true)
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic: :community_news, channel: :whatsapp, enabled: false)

          report = compare_class.new(organization: @organization, samples: samples).run

          assert_equal 0, report.added
          assert_equal 0, report.removed
          assert_predicate report, :equivalent?
          assert_operator report.evaluated, :>, 0
        end

        test "equal totals are not accepted as equivalence: the sets themselves are compared" do
          report = compare_class.new(organization: @organization, samples: samples).run

          assert_respond_to report, :differences
          assert_equal report.evaluated, report.unchanged + report.added + report.removed
        end

        test "canonical topic choices remain equivalent across rollout modes" do
          Decidim::Bih::TopicPreferences.set!(@citizen, topic: :report_updates, enabled: false)
          %w(compatibility target).each do |mode|
            report = compare_class.new(organization: @organization, samples: samples, mode:).run
            assert_predicate report, :equivalent?
            assert_equal 0, report.added
            assert_equal 0, report.removed
          end
        end

        test "transport suppression remains equivalent across rollout modes" do
          Decidim::Bih::Messaging::TransportSuppression.suppress!(
            organization: @organization, provider: "infobip", channel: "viber", destination_kind: "phone",
            destination_digest: @digest, reason: "provider_opt_out", source: "provider_webhook", user: @citizen
          )
          report = compare_class.new(organization: @organization, samples: samples, mode: "target").run
          assert_predicate report, :equivalent?
        end

        test "the retained artifact is aggregate: counts, reasons and versions, no identifiers" do
          report = compare_class.new(organization: @organization, samples: samples).run
          serialised = report.to_h.to_s

          assert_includes report.to_h.keys, :reason_counts
          assert_includes report.to_h.keys, :policy_version
          assert_not_includes serialised, @citizen.email
          assert_not_includes serialised, @citizen.nickname
          assert_not_includes serialised, @digest
        end

        test "coverage is reported per class and channel, not implied by elapsed time" do
          report = compare_class.new(organization: @organization, samples: samples).run

          assert_predicate report, :sufficient_coverage?
          assert_equal report.evaluated, report.coverage.values.sum
          assert_includes report.coverage.keys, ["report.author_external_copy", "viber"]
        end

        test "a contract nobody exercised is reported as uncovered rather than passing quietly" do
          partial = samples.first(1)
          report = compare_class.new(organization: @organization, samples: partial).run
          full = compare_class.new(organization: @organization, samples:).run

          assert_operator full.coverage.keys.length, :>, report.coverage.keys.length
        end

        test "adverse contexts are compared too, and agree in compatibility mode" do
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic: :report_updates, channel: :viber, enabled: true)
          adverse = samples.map do |sample|
            sample.merge(context: sample.fetch(:context).merge(deadline_at: 1.minute.ago, channel_configured: false))
          end

          report = compare_class.new(organization: @organization, samples: adverse).run

          assert_predicate report, :equivalent?
          assert_operator report.reason_counts.values.sum, :>, 0
        end

        # ---- dispatch evidence -------------------------------------------------

        test "an intent records its decision, versions and a safe reference for a recipient with no account" do
          recipient = context_class.anonymous_report_contact(
            organization_id: @organization.id, destination: "reporter@example.org", destination_channel: "email"
          )
          decision = Decidim::Bih::Messaging::Policy.decide(
            organization: @organization, message_class: "report.reporter_status_email",
            recipient:, channel: "email", context: { destination_present: true, initial_status: false }
          )
          intent = evidence.record_intent!(
            organization: @organization, message_class: "report.reporter_status_email", recipient:,
            decision:, correlation_key: "report:1:status:u_obradi", deduplication_scope: "report_status"
          )

          assert_nil intent.decidim_user_id
          assert_not_nil intent.recipient_reference
          assert_not_includes intent.recipient_reference, "@"
          assert_equal decision.policy_version, intent.policy_version
        end

        test "a ledger failure before the claim prevents the send" do
          intent = shadow_intent
          exploded = ->(*) { raise ActiveRecord::StatementInvalid, "ledger down" }
          sent = false

          assert_raises(Decidim::Bih::Messaging::DispatchEvidence::LedgerUnavailable) do
            Decidim::Bih::Messaging::Attempt.stub(:create!, exploded) do
              intent.attempts.stub(:create!, exploded) do
                evidence.with_claim(intent:, channel_group: "external_copy", channel: "viber") { sent = true }
              end
            end
          end

          assert_not sent, "an unrecorded paid send is the one outcome nobody can reconcile"
        end

        test "a failure after the provider call becomes uncertain, never a retry instruction" do
          intent = shadow_intent
          outcome = evidence.with_claim(intent:, channel_group: "external_copy", channel: "viber") do
            raise Timeout::Error, "no reply from provider"
          end

          assert_predicate outcome, :uncertain?
          assert_equal "uncertain", intent.attempts.first.reload.status
          assert_equal 1, intent.attempts.count, "an uncertain outcome must not create a second attempt"
        end

        test "per-device fan-out is several attempts of one intent" do
          intent = shadow_intent
          2.times do |index|
            evidence.with_claim(intent:, channel_group: "push", channel: "push",
                                destination_version: "device-#{index}") { { "messageId" => "m#{index}" } }
          end

          assert_equal 2, intent.attempts.where(channel: "push").count
          assert_equal %w(accepted accepted), intent.attempts.where(channel: "push").pluck(:status)
        end

        test "diagnostics expose correlation gaps and stuck work as aggregates" do
          intent = shadow_intent
          evidence.with_claim(intent:, channel_group: "external_copy", channel: "viber") { { "messageId" => "m1" } }
          shadow_intent(correlation_key: "report:9:status:rijeseno")

          diagnostics = evidence.diagnostics(organization: @organization)

          assert_equal 2, diagnostics[:intents]
          assert_equal 1, diagnostics[:intents_without_attempt]
          assert_equal({ "accepted" => 1 }, diagnostics[:by_status])
        end

        private

        def shadow_intent(correlation_key: "report:1:status:rijeseno")
          recipient = context_class.account(organization_id: @organization.id, account_id: @citizen.id)
          decision = Decidim::Bih::Messaging::Policy.decide(
            organization: @organization, message_class: "report.author_external_copy",
            recipient:, channel: "viber", context: { destination_digest: @digest }
          )
          evidence.record_intent!(
            organization: @organization, message_class: "report.author_external_copy", recipient:,
            decision:, correlation_key:, deduplication_scope: "report_status"
          )
        end

        # A small, deliberate sample set: the enrolled classes, the channels
        # they actually use, and the contexts those messages actually carry.
        # Not a Cartesian product of every citizen against every channel.
        def samples
          recipient = context_class.account(organization_id: @organization.id, account_id: @citizen.id)
          [
            { message_class: "report.author_external_copy", recipient:,
              context: { destination_digest: @digest } },
            { message_class: "campaign.marketing_phone", recipient:,
              context: { destination_digest: @digest } },
            { message_class: "city.service_alert_viber", recipient:,
              context: { destination_digest: @digest } }
          ]
        end
      end
    end
  end
end
