# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 1.3: characterise what the platform does today, then prove the
      # candidate implementation agrees with it before anybody is allowed to
      # change behaviour.
      #
      # `legacy` is the characterisation. `compatibility` is the candidate
      # reading the new store where it exists and the old JSON where it does
      # not, and it must reach the SAME answer. `target` is where D3/D4 changes
      # live, and each difference has to be deliberate.
      class MessagingPolicyTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        # Resolved lazily inside the examples rather than at class-body level:
        # a missing constant in a class body aborts the whole harness at LOAD
        # time, which turns one red test into "no tests ran at all".
        def policy = Decidim::Bih::Messaging::Policy

        def modes_class = Decidim::Bih::Messaging::Modes

        def context_class = Decidim::Bih::Messaging::RecipientContext

        setup do
          @organization = create_organization
          @other_organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @digest = Digest::SHA256.hexdigest("+38765000000")
        end

        # ---- class and channel safety ---------------------------------------

        test "an unknown message class is refused before anything else happens" do
          assert_raises(Decidim::Bih::Messaging::MessageClass::UnknownMessageClass) do
            policy.decide(organization: @organization, message_class: "not.real",
                          recipient: account_recipient, channel: "viber")
          end
        end

        test "a channel the class does not support is denied, not improvised" do
          decision = policy.decide(organization: @organization, message_class: "city.service_alert_viber",
                                   recipient: account_recipient, channel: "sms", context: phone_context)

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :unsupported_channel
        end

        test "bell and push never enter the external topic adapter" do
          %w(bell push).each do |channel|
            assert_raises(Decidim::Bih::Messaging::MessageClass::UnsupportedChannel) do
              Decidim::Bih::Messaging::LegacyAdapters.stored_topic_key(
                "community_news_topic", user: @citizen, channel:
              )
            end
          end
        end

        # ---- recipient and tenant -------------------------------------------

        test "a deleted or blocked account is not a recipient" do
          allow_topic!(:report_updates, "viber")
          [:deleted, :blocked].each do |state|
            user = FactoryBot.create(:user, :confirmed, organization: @organization)
            state == :deleted ? user.update!(deleted_at: Time.current) : user.update!(blocked: true, blocked_at: Time.current)
            decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                     recipient: account_recipient(user), channel: "viber", context: phone_context)

            assert_predicate decision, :denied?
            assert_includes decision.reason_codes, :account_unavailable
          end
        end

        test "an account from another organization is refused as the wrong tenant" do
          stranger = FactoryBot.create(:user, :confirmed, organization: @other_organization)
          recipient = context_class.account(organization_id: @other_organization.id, account_id: stranger.id)
          decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                   recipient:, channel: "viber", context: phone_context)

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :wrong_tenant
        end

        test "an invalid recipient context is classified rather than guessed" do
          recipient = context_class.account(organization_id: @organization.id, account_id: nil)
          decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                   recipient:, channel: "viber", context: phone_context)

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :invalid_recipient_context
        end

        # ---- authentication --------------------------------------------------

        test "requested phone verification does not require an already verified phone" do
          recipient = context_class.pending_authentication(organization_id: @organization.id, destination: "+38765000000")
          decision = policy.decide(organization: @organization, message_class: "authentication.phone_verification",
                                   recipient:, channel: "sms",
                                   context: { request_valid: true, destination_digest: @digest })

          assert_predicate decision, :permitted?
          assert_equal "exempt", decision.preference_origin
        end

        test "an invalid authentication request is refused even though it has no topic switch" do
          recipient = context_class.pending_authentication(organization_id: @organization.id, destination: "+38765000000")
          decision = policy.decide(organization: @organization, message_class: "authentication.phone_verification",
                                   recipient:, channel: "sms",
                                   context: { request_valid: false, destination_digest: @digest })

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :invalid_request
        end

        test "a marketing block does not switch off a requested authentication message" do
          block_topic!(:community_news, "viber")
          recipient = context_class.pending_authentication(organization_id: @organization.id, destination: "+38765000000")
          decision = policy.decide(organization: @organization, message_class: "authentication.phone_verification",
                                   recipient:, channel: "viber",
                                   context: { request_valid: true, destination_digest: @digest })

          assert_predicate decision, :permitted?
        end

        # ---- anonymous report contact ----------------------------------------

        test "a report status e-mail addresses the report's own contact, with no account lookup" do
          recipient = context_class.anonymous_report_contact(
            organization_id: @organization.id, destination: "reporter@example.org", destination_channel: "email",
            resource_type: "Decidim::Bih::Report", resource_id: 7
          )
          decision = policy.decide(organization: @organization, message_class: "report.reporter_status_email",
                                   recipient:, channel: "email",
                                   context: { destination_present: true, initial_status: false })

          assert_predicate decision, :permitted?
          assert_equal "report", decision.preference_origin
          assert_not recipient.account_lookup_allowed?
        end

        test "the initial primljeno transition does not notify" do
          recipient = context_class.anonymous_report_contact(
            organization_id: @organization.id, destination: "reporter@example.org", destination_channel: "email"
          )
          decision = policy.decide(organization: @organization, message_class: "report.reporter_status_email",
                                   recipient:, channel: "email",
                                   context: { destination_present: true, initial_status: true })

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :initial_status_not_notified
        end

        # ---- legacy stored values --------------------------------------------

        test "missing topic preferences default on and stale legacy JSON cannot override a topic" do
          assert_predicate decide(mode: "legacy"), :permitted?
          write_setting!("mi_report_updates_viber", false)
          assert_predicate decide(mode: "legacy"), :permitted?
          Decidim::Bih::TopicPreferences.set!(@citizen, topic: :report_updates, enabled: false)
          write_setting!("mi_report_updates_viber", true)
          assert_predicate decide(mode: "legacy"), :denied?
        end

        test "the urgent board bell is always available even when proactive neighborhood messages are disabled" do
          write_setting!("komsiluk_board", false)
          Decidim::Bih::TopicPreferences.set!(@citizen, topic: :neighborhood_info, enabled: false)
          decision = policy.decide(organization: @organization, message_class: "komsiluk.urgent_post",
                                   recipient: account_recipient, channel: "bell", context: {})
          assert_predicate decision, :permitted?
        end

        test "a report external copy is blockable even when its direct bell is not" do
          block_topic!(:report_updates, "viber")

          bell = policy.decide(organization: @organization, message_class: "report.case_message_to_author",
                               recipient: account_recipient, channel: "bell", context: {})
          copy = policy.decide(organization: @organization, message_class: "report.case_message_to_author",
                               recipient: account_recipient, channel: "viber", context: phone_context)

          assert_predicate bell, :permitted?
          assert_predicate copy, :denied?
          assert_includes copy.reason_codes, :preference_blocked
        end

        # ---- transport and provider gates -------------------------------------

        test "an expired deadline, an unconfigured channel, a bad template and a dead session are separate reasons" do
          cases = {
            { deadline_at: 1.minute.ago } => :expired,
            { channel_configured: false } => :channel_unconfigured,
            { template_valid: false } => :template_required,
            { connection_present: false } => :connection_required
          }
          allow_topic!(:report_updates, "viber")
          cases.each do |extra, reason|
            decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                     recipient: account_recipient, channel: "viber",
                                     context: phone_context.merge(extra))

            assert_includes decision.reason_codes, reason
            assert_predicate decision, :denied?
          end
        end

        test "a missing destination is a classified non-send, not invented reachability" do
          allow_topic!(:report_updates, "viber")
          decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                   recipient: account_recipient, channel: "viber", context: {})

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :destination_unknown
        end

        test "an expired social session is refused" do
          allow_topic!(:report_updates, "messenger")
          decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                   recipient: account_recipient, channel: "messenger",
                                   context: { destination_digest: @digest, session_expires_at: 1.hour.ago })

          assert_predicate decision, :denied?
          assert_includes decision.reason_codes, :session_expired
        end

        # ---- modes -------------------------------------------------------------

        test "all routing modes use the same canonical topic choice on every channel" do
          [true, false].each do |enabled|
            Decidim::Bih::TopicPreferences.set!(@citizen, topic: :report_updates, enabled:)
            %w(legacy compatibility target).each do |mode|
              assert_equal enabled, decide(mode:).permitted?
              decision = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                       recipient: account_recipient, channel: "whatsapp", mode:, context: phone_context)
              assert_equal enabled, decision.permitted?
            end
          end
        end

        test "a destination STOP blocks every mode without blocking the topic on another transport" do
          Decidim::Bih::Messaging::Suppression.create!(
            organization: @organization, provider: "infobip", channel: "viber", destination_kind: "phone",
            destination_digest: @digest, address_version: 1, reason: "provider_opt_out",
            source: "provider_webhook", suppressed_at: Time.current, user: @citizen
          )
          %w(legacy compatibility target).each do |mode|
            assert_includes decide(mode:).reason_codes, :transport_suppressed
            other = policy.decide(organization: @organization, message_class: "report.author_external_copy",
                                  recipient: account_recipient, channel: "whatsapp", mode:, context: phone_context)
            assert_predicate other, :permitted?
          end
          assert Decidim::Bih::TopicPreferences.enabled?(@citizen, topic: :report_updates)
        end

        test "push obeys the classified topic and a disabled unrelated topic does not block it" do
          Decidim::Bih::TopicPreferences.set!(@citizen, topic: :community_news, enabled: false)
          args = { organization: @organization, message_class: "report.case_message_to_author",
                   recipient: account_recipient, channel: "push", context: { device_count: 1, notification_topic: "report_updates" } }
          assert_predicate policy.decide(**args), :permitted?
          Decidim::Bih::TopicPreferences.set!(@citizen, topic: :report_updates, enabled: false)
          assert_predicate policy.decide(**args), :denied?
        end

        test "routing mode flags do not change canonical default-on permission" do
          clear_setting!("mi_report_updates_viber")
          Decidim::Bih::Messaging::OrganizationPolicy.create!(
            organization: @organization, policy_version: "mi-2026-09-14", effective_from: Time.current,
            active: true, defaults: { "report_updates" => { "viber" => "allowed" } }
          )

          assert_equal "legacy", modes_class.new(organization: @organization).for("report.author_external_copy")
          assert_predicate decide, :permitted?

          Decidim::Bih::Setting.put(@organization, "messaging", "mode.report.author_external_copy", "target")

          assert_equal "target", modes_class.new(organization: @organization).for("report.author_external_copy")
          assert_predicate decide, :permitted?
        end

        test "a producer that is not enrolled can never be moved off legacy by a flag" do
          Decidim::Bih::Setting.put(@organization, "messaging", "mode.default", "target")

          assert_equal "legacy", modes_class.new(organization: @organization).for("authentication.phone_verification")
          assert_equal "target", modes_class.new(organization: @organization).for("report.author_external_copy")
        end

        test "dispatch can be disabled independently of the mode" do
          modes = modes_class.new(organization: @organization)

          assert_not modes.dispatch_disabled?("report.author_external_copy")

          Decidim::Bih::Setting.put(@organization, "messaging", "dispatch_disabled.default", "1")

          assert_predicate modes_class.new(organization: @organization), :snapshot
          assert modes_class.new(organization: @organization).dispatch_disabled?("report.author_external_copy")
        end

        # ---- read-only guarantee ---------------------------------------------------

        test "deciding writes nothing and enqueues nothing" do
          allow_topic!(:report_updates, "viber")
          before = table_counts

          assert_no_enqueued_jobs do
            10.times { decide(mode: "compatibility") }
            decide(mode: "target")
            decide(mode: "legacy")
          end

          assert_equal before, table_counts
        end

        private

        def decide(mode: nil)
          policy.decide(organization: @organization, message_class: "report.author_external_copy",
                        recipient: account_recipient, channel: "viber", context: phone_context, mode:)
        end

        def account_recipient(user = @citizen)
          context_class.account(organization_id: @organization.id, account_id: user.id)
        end

        def phone_context
          { destination_digest: @digest }
        end

        def table_counts
          {
            preferences: Decidim::Bih::Messaging::Preference.count,
            changes: Decidim::Bih::Messaging::PreferenceChange.count,
            intents: Decidim::Bih::Messaging::Intent.count,
            attempts: Decidim::Bih::Messaging::Attempt.count,
            account_notifications: Decidim::Bih::AccountNotification.count
          }
        end

        def allow_topic!(topic, channel)
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic:, channel:, enabled: true)
          @citizen.reload
        end

        def block_topic!(topic, channel)
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic:, channel:, enabled: false)
          @citizen.reload
        end

        def write_setting!(key, value)
          settings = @citizen.notification_settings.to_h.deep_dup
          settings[key] = value
          @citizen.update!(notification_settings: settings)
          @citizen.reload
        end

        def clear_setting!(key)
          settings = @citizen.notification_settings.to_h.deep_dup
          settings.delete(key)
          @citizen.update!(notification_settings: settings)
          @citizen.reload
        end
      end
    end
  end
end
