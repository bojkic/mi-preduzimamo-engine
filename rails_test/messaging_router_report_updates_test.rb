# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 2.3 — report correspondence enrolled in COMPATIBILITY mode.
      #
      # Three distinctions this file exists to keep apart, because blurring them
      # is how a private case reply ends up in the wrong place:
      #
      #   1. The direct bell, the per-report e-mail and the account external
      #      copy are THREE GROUPS, not three channels of one. The bell is
      #      created directly and is not blockable by a topic choice; the report
      #      e-mail goes to the report's own contact address and is not governed
      #      by `report_updates` at all; only the external copy is.
      #   2. WhatsApp report content is NOT Viber report content. The approved
      #      template carries a reference and a status and nothing else — no
      #      staff body, no private reply link — so the registry carries two
      #      different content variants and this file asserts they differ.
      #   3. Terminal history is terminal. The four `skipped`/`ineligible` rows
      #      and the `delivered` rows that followed them are observations, not a
      #      backlog. Enrolling a class must not replay, rewrite or resend one.
      #
      # Nothing here enrolls a production organization: every mode is written
      # into this test's own organization's `Setting` rows.
      class MessagingRouterReportUpdatesTest < ActiveSupport::TestCase
        STATUS_COPY_CLASS = "report.author_external_copy"
        CASE_MESSAGE_CLASS = "report.case_message_to_author"

        # A stand-in for the Messages API. It records what it was asked to send
        # so a test can prove the transport was NOT called.
        class ClientDouble
          attr_accessor :error, :response, :viber_configured
          attr_reader :calls

          def initialize
            @calls = []
            @viber_configured = true
          end

          def configured? = true

          def viber_business_configured? = viber_configured

          def chat_channel_configured?(_channel) = false

          def message_delivery_reports(**) = { "results" => [] }

          def send_phone_message(**options)
            @calls << options
            raise error if error

            response || { "messages" => [{ "messageId" => "provider-1" }] }
          end
        end

        def messaging = Decidim::Bih::Messaging

        def router = Decidim::Bih::Messaging::Router

        def notifications = Decidim::Bih::AccountNotifications

        setup do
          @organization = create_organization
          @author = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::NotificationPreferences.set!(@author, topic: :report_updates, channel: :viber, enabled: true)
          Decidim::Bih::NotificationPreferences.set!(@author, topic: :report_updates, channel: :whatsapp, enabled: true)
          @client = ClientDouble.new
        end

        def enroll!(message_class, mode)
          Decidim::Bih::Setting.put(@organization, messaging::Modes::NAMESPACE, "mode.#{message_class}", mode)
        end

        def disable_dispatch!(message_class)
          Decidim::Bih::Setting.put(@organization, messaging::Modes::NAMESPACE, "dispatch_disabled.#{message_class}", true)
        end

        def recipient
          messaging::RecipientContext.account(organization_id: @organization.id, account_id: @author.id)
        end

        # `device_count` is not decoration: the push group's adapter is
        # `device_subscription`, and a browser permission nobody granted means
        # no push group at all. A plan built without it would quietly have two
        # groups and this file would be asserting the wrong shape.
        def plan_for(message_class, mode: :compatibility, **context)
          router.plan(message_class:, recipient:, organization: @organization, mode:,
                      context: { destination_present: true, device_count: 1 }.merge(context))
        end

        def enqueue!(message_class: STATUS_COPY_CLASS, key: "report:1:u_obradi", channels: %w(viber whatsapp))
          notifications.enqueue!(user: @author, organization: @organization, topic: :report_updates,
                                 text: "Tvoja prijava ima novi status.", deduplication_key: key,
                                 channels:, message_class:, enqueue_job: false)
        end

        def with_delivery(phone: "+38765111001", &)
          Decidim::Bih::Infobip::Client.stub(:new, @client) do
            Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, phone, &)
          end
        end

        # WhatsApp is unconfigured in a bare harness host, which would make
        # every scenario collapse onto Viber and compare nothing.
        def with_whatsapp_configured(&)
          Decidim::Bih::Config.stub(:infobip,
                                    Decidim::Bih::Config.infobip.merge(messages_api_enabled: true,
                                                                       whatsapp_sender: "38765000000"), &)
        end

        # ---- the three groups stay three groups -----------------------------

        test "a device nobody subscribed means no push group, which is the shape without one" do
          plan = plan_for(CASE_MESSAGE_CLASS, device_count: 0)

          assert_equal %w(bell external_copy), plan.groups.map(&:name)
          assert_includes plan.suppressed_reasons, :no_device_subscription
        end

        test "the direct bell, the push fanout and the external copy are three independent groups" do
          plan = plan_for(CASE_MESSAGE_CLASS)

          assert_equal %w(bell push external_copy), plan.groups.map(&:name)
          assert plan.groups.none?(&:terminates_siblings)
          assert_equal(1, plan.groups.count { |group| group.name == "external_copy" })
        end

        test "a disabled report topic suppresses proactive copies while retaining the inbox" do
          [:viber, :whatsapp, :messenger, :instagram].each do |channel|
            Decidim::Bih::NotificationPreferences.set!(@author, topic: :report_updates, channel:, enabled: false)
          end

          plan = plan_for(CASE_MESSAGE_CLASS)

          assert_equal %w(bell), plan.groups.map(&:name)
          assert_includes plan.suppressed_reasons, :preference_blocked
        end

        test "the bell group is not governed by the topic the external copy is governed by" do
          plan = plan_for(CASE_MESSAGE_CLASS)

          bell = plan.group("bell")
          external = plan.group("external_copy")
          assert_equal "none", bell.preference_adapter
          assert_equal "report_updates_topic", external.preference_adapter
        end

        # ---- WhatsApp content is not Viber content --------------------------

        test "the whatsapp variant is a different content variant from the viber one, and the plan says so" do
          external = plan_for(CASE_MESSAGE_CLASS).group("external_copy")

          assert_equal "reference_and_status_only", external.content_variant_for("whatsapp")
          assert_equal "full_case_text", external.content_variant_for("viber")
          assert_not_equal external.content_variant_for("whatsapp"), external.content_variant_for("viber")
        end

        test "the status copy carries its own pair of variants, also not identical" do
          external = plan_for(STATUS_COPY_CLASS).group("external_copy")

          assert_equal "reference_and_status_only", external.content_variant_for("whatsapp")
          assert_equal "full_status_text", external.content_variant_for("viber")
        end

        # ---- enrollment -----------------------------------------------------

        test "legacy mode never runs the router" do
          notification = enqueue!
          messaging::RoutedDispatch.stub(:new, ->(**) { flunk "the router must not run in legacy mode" }) do
            with_delivery { notifications.dispatch!(notification) }
          end

          assert_equal "accepted", notification.reload.status
          assert_equal 0, messaging::Intent.where(organization: @organization).count
        end

        test "a payload with no message class stays on the legacy body forever" do
          notification = notifications.enqueue!(user: @author, organization: @organization, topic: :report_updates,
                                                text: "Bez klase", deduplication_key: "legacy-only", enqueue_job: false)
          enroll!(STATUS_COPY_CLASS, "compatibility")

          with_delivery { notifications.dispatch!(notification) }

          assert_equal "accepted", notification.reload.status
          assert_equal 0, messaging::Intent.where(organization: @organization).count
        end

        # The G1 question, asked of the real thing: does the routed dispatch
        # select the channels the legacy selection would have selected? Equal
        # totals would prove nothing, so this compares the SETS, and it asserts
        # afterwards that all three shapes were actually reached — a comparison
        # that only ever exercised one branch has compared almost nothing.
        test "the routed channel set equals the legacy selection in every configuration tried" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          template = { name: "mi_status_prijave_v1", language: "sr", body: { "1" => "PR-1", "2" => "u obradi" } }
          observed = []

          [
            { viber_configured: true, template: nil },
            { viber_configured: false, template: },
            { viber_configured: true, template: }
          ].each_with_index do |scenario, index|
            @client.viber_configured = scenario[:viber_configured]
            notification = notifications.enqueue!(
              user: @author, organization: @organization, topic: :report_updates, text: "Tvoja prijava",
              deduplication_key: "equivalence-#{index}", template: scenario[:template],
              channels: %w(viber whatsapp), message_class: STATUS_COPY_CLASS, enqueue_job: false
            )
            legacy = with_whatsapp_configured do
              with_delivery do
                notifications.preview(user: @author, organization: @organization, topic: "report_updates",
                                      text: "Tvoja prijava", template: scenario[:template], channels: %w(viber whatsapp))
              end
            end
            with_whatsapp_configured { with_delivery { notifications.dispatch!(notification) } }
            observed << legacy[:channels].map(&:to_s)

            assert_equal legacy[:channels].map(&:to_s).sort, notification.reload.channels.map(&:to_s).sort,
                         "scenario #{index} (#{scenario[:viber_configured]}) diverged; reasons=#{legacy[:reasons]}"
          end

          assert_includes observed, %w(viber), "the viber-only branch was never exercised"
          assert_includes observed, %w(whatsapp), "the whatsapp-only branch was never exercised"
          assert_includes observed, %w(viber whatsapp), "the two-channel branch was never exercised"
        end

        test "a routed dispatch records one intent and one claimed attempt" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!

          with_delivery { notifications.dispatch!(notification) }

          intents = messaging::Intent.where(organization: @organization)
          assert_equal 1, intents.count
          intent = intents.first
          assert_equal STATUS_COPY_CLASS, intent.message_class
          assert_equal "compatibility", intent.mode
          assert_equal notification.id, intent.decidim_bih_account_notification_id
          assert_equal 1, intent.attempts.count
          assert_equal "accepted", intent.attempts.first.status
          assert_equal "accepted", notification.reload.status
          assert_equal ["provider-1"], notification.provider_message_ids
        end

        test "dispatching the same intent twice adds no second intent and sends nothing again" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!

          with_delivery { 2.times { notifications.dispatch!(notification.reload) } }

          assert_equal 1, @client.calls.size
          assert_equal 1, messaging::Intent.where(organization: @organization).count
          assert_equal 1, messaging::Attempt.count
        end

        test "two different business events get two isolated intents" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          first = enqueue!(key: "report:1:u_obradi")
          second = enqueue!(key: "report:1:rijeseno")

          with_delivery do
            notifications.dispatch!(first)
            notifications.dispatch!(second)
          end

          intents = messaging::Intent.where(organization: @organization)
          assert_equal 2, intents.count
          assert_equal 2, intents.pluck(:deduplication_scope).uniq.size
          assert_equal 2, @client.calls.size
        end

        test "dispatch_disabled refuses to act without rolling the mode back, and never falls through to the legacy body" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          disable_dispatch!(STATUS_COPY_CLASS)
          notification = enqueue!

          with_delivery { notifications.dispatch!(notification) }

          assert_empty @client.calls
          assert_equal "skipped", notification.reload.status
          assert_equal "dispatch_disabled", notification.reason
          assert_equal :compatibility,
                       messaging::Enrollment.mode(organization: @organization, message_class: STATUS_COPY_CLASS)
          assert_equal 0, messaging::Intent.where(organization: @organization).count
        end

        test "a preference already withdrawn is refused before any claim exists" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!(channels: %w(viber))
          [:viber, :whatsapp].each do |channel|
            Decidim::Bih::NotificationPreferences.set!(@author, topic: :report_updates, channel:, enabled: false)
          end

          with_delivery { notifications.dispatch!(notification) }

          assert_empty @client.calls
          assert_equal "skipped", notification.reload.status
          assert_equal "ineligible", notification.reason
          assert_equal 0, messaging::Attempt.count, "nothing may be claimed for a plan with no permitted group"
        end

        # The rule is "recheck immediately before the irreversible send", and a
        # test that withdraws the preference BEFORE dispatch proves only that the
        # plan is built correctly. This withdraws it between the plan and the
        # send — the reachability read inside the claim is the seam — so the
        # claim exists and the transport still must not be called.
        test "a preference withdrawn between the plan and the send is refused inside the claim" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!(channels: %w(viber))
          reads = 0
          phone = lambda do |user:, organization:| # rubocop:disable Lint/UnusedBlockArgument
            reads += 1
            Decidim::Bih::NotificationPreferences.set!(@author, topic: :report_updates, channel: :viber, enabled: false) if reads == 2
            "+38765111001"
          end

          Decidim::Bih::Infobip::Client.stub(:new, @client) do
            Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, phone) do
              notifications.dispatch!(notification)
            end
          end

          assert_empty @client.calls, "the transport must not run after a late refusal"
          assert_equal "skipped", notification.reload.status
          assert_equal 1, messaging::Attempt.count, "the claim exists; only the send was stopped"
          assert_equal "skipped", messaging::Attempt.last.status
        end

        # ---- terminal history -----------------------------------------------

        test "a historically skipped intent is untouched by enrollment" do
          skipped = enqueue!(key: "historic-skipped")
          skipped.update!(status: "skipped", reason: "ineligible", channels: [])
          enroll!(STATUS_COPY_CLASS, "compatibility")

          with_delivery do
            notifications.recover_pending!
            notifications.dispatch!(skipped.reload)
          end

          assert_equal "skipped", skipped.reload.status
          assert_equal "ineligible", skipped.reason
          assert_nil skipped.attempted_at
          assert_empty @client.calls
          assert_equal 0, messaging::Intent.where(organization: @organization).count
        end

        # Found by mutation: no test anywhere covered the LEGACY body's own
        # "only a pending record may be claimed" guard, so deleting it was free.
        # Terminal history has to be safe on both sides of the branch.
        test "the legacy body also refuses to re-claim a terminal record" do
          skipped = enqueue!(key: "legacy-historic")
          skipped.update!(status: "skipped", reason: "ineligible", channels: [])

          with_delivery { notifications.dispatch!(skipped.reload) }

          assert_equal "skipped", skipped.reload.status
          assert_equal "ineligible", skipped.reason
          assert_nil skipped.attempted_at
          assert_empty @client.calls
        end

        test "a delivered record is never resent because its class was enrolled" do
          delivered = enqueue!(key: "historic-delivered")
          delivered.update!(status: "delivered", channels: %w(viber), delivered_at: 1.hour.ago,
                            provider_message_ids: ["provider-historic"])
          enroll!(STATUS_COPY_CLASS, "compatibility")

          with_delivery do
            notifications.recover_pending!
            notifications.dispatch!(delivered.reload)
          end

          assert_equal "delivered", delivered.reload.status
          assert_equal ["provider-historic"], delivered.provider_message_ids
          assert_empty @client.calls
          assert_equal 0, messaging::Intent.where(organization: @organization).count
        end

        test "an expired intent is skipped before any claim and never routed" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!(key: "already-expired")
          notification.update!(expires_at: 1.minute.ago)

          with_delivery { notifications.dispatch!(notification) }

          assert_empty @client.calls
          assert_equal "skipped", notification.reload.status
          assert_equal "expired", notification.reason
        end

        # ---- the outcome vocabulary -----------------------------------------

        test "a response with no message id settles uncertain, not accepted, and is not retried" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!
          @client.response = { "messages" => [] }

          with_delivery { notifications.dispatch!(notification) }

          assert_equal "unknown", notification.reload.status
          assert_equal "missing_provider_id", notification.reason
          assert_equal "uncertain", messaging::Attempt.last.status
        end

        test "a definitive provider rejection is recorded as a failed attempt with its own reason" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          notification = enqueue!
          @client.error = Decidim::Bih::Infobip::Error.new("refused", http_status: 400, error_code: "NO_SUCH_USER")

          with_delivery { notifications.dispatch!(notification) }

          assert_equal "rejected", notification.reload.status
          assert_equal "NO_SUCH_USER", notification.reason
          assert_equal "failed", messaging::Attempt.last.status
        end

        # ---- G1: the delivery-set comparison --------------------------------

        # The honest Phase 2 G1 result is "no delivery-set change", and this is
        # it demonstrated rather than asserted. An organization that has no
        # `messaging` Setting row — which is every organization in production
        # on this date — routes NOTHING, whatever the registry says, so every
        # enrolled caller runs the same legacy body it ran before the release.
        test "an organization with no messaging setting rows routes nothing at all" do
          enrolled = messaging::MessageClass.enrolled
          assert_operator enrolled.size, :>=, 7, "the registry lost its enrolled classes"

          enrolled.each_key do |key|
            assert_equal :legacy, messaging::Enrollment.mode(organization: @organization, message_class: key), key
            refute messaging::Enrollment.routes?(organization: @organization, message_class: key), key
            assert messaging::Enrollment.shadow_observed?(organization: @organization, message_class: key), key
          end
        end

        # `RoutingPlan#delivery_set` is the comparator G1 asks for: ordered,
        # deterministic and recipient-free, so two modes can be diffed without
        # a recipient list ever existing. Equal counts would prove nothing —
        # this compares the sets, including every suppression and its reason
        # codes. They are equal today because no organization policy has been
        # activated, which is the fact that makes "target adds nobody" checkable
        # instead of hopeful.
        test "compatibility and target produce the same delivery set for every routable report class" do
          assert_equal 0, messaging::OrganizationPolicy.where(organization: @organization).count,
                       "an activated organization default would move the target set; recompute the ceiling"

          [STATUS_COPY_CLASS, CASE_MESSAGE_CLASS].each do |key|
            compatibility = plan_for(key, mode: :compatibility)
            target = plan_for(key, mode: :target)

            # A comparison of two empty plans compares nothing, so the plan
            # is proved non-trivial before it is proved equal.
            assert compatibility.deliverable?, key
            assert compatibility.group("external_copy"), key
            assert_not_empty compatibility.group("external_copy").channels, key
            assert_equal compatibility.delivery_set, target.delivery_set, key
            assert_equal [], compatibility.delivery_set[:suppressed] - target.delivery_set[:suppressed], key
          end
        end

        # A delivery set that carried a recipient identifier could not be
        # published as G1 evidence at all, so the property is asserted rather
        # than assumed.
        test "a delivery set carries no recipient identifier" do
          set = plan_for(STATUS_COPY_CLASS).delivery_set

          refute_includes set.keys, :recipient_ref
          refute_includes set.to_s, @author.id.to_s
          refute_includes set.to_s, @author.email
        end

        # ---- G2: the rehearsed rollback -------------------------------------

        # Rollback is one row, per organization, and it is the same row that
        # enrolled the class. `refresh_latency_seconds == 0` is the claim; this
        # exercises it instead of restating it — the flag is flipped between two
        # dispatches in one process and the second one runs the legacy body.
        test "rollback to legacy stops routing on the very next dispatch, with no restart" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          assert messaging::Enrollment.routes?(organization: @organization, message_class: STATUS_COPY_CLASS)

          routed = enqueue!(key: "rollback:before")
          with_delivery { notifications.dispatch!(routed) }
          assert_equal 1, messaging::Intent.where(organization: @organization).count

          enroll!(STATUS_COPY_CLASS, "legacy") # the rollback

          assert_equal 0, messaging::Enrollment.refresh_latency_seconds
          assert_equal :legacy, messaging::Enrollment.mode(organization: @organization, message_class: STATUS_COPY_CLASS)
          refute messaging::Enrollment.routes?(organization: @organization, message_class: STATUS_COPY_CLASS)

          after = enqueue!(key: "rollback:after")
          messaging::RoutedDispatch.stub(:new, ->(**) { flunk "the router ran after a rollback" }) do
            with_delivery { notifications.dispatch!(after) }
          end

          assert_equal "accepted", after.reload.status, "the legacy body must still deliver"
          assert_equal 1, messaging::Intent.where(organization: @organization).count,
                       "a rolled-back class must write no further routed evidence"
          assert_equal "compatibility", messaging::Intent.where(organization: @organization).first.mode,
                       "the evidence written while routed is history, not something rollback rewrites"
        end

        # The four work states the roadmap's G2 names, in one transaction of
        # time: never attempted, claimed, accepted, already uncertain. The
        # rollback must resolve each one the way the platform resolves it
        # anyway, and must invent no new resolution of its own.
        test "rollback leaves pending, claimed, accepted and unknown work correct" do
          enroll!(STATUS_COPY_CLASS, "compatibility")

          pending = enqueue!(key: "rollback:pending")
          pending.update!(created_at: 5.minutes.ago)
          claimed = enqueue!(key: "rollback:claimed")
          claimed.update!(status: "sending", attempted_at: 45.minutes.ago)
          accepted = enqueue!(key: "rollback:accepted")
          accepted.update!(status: "accepted", channels: %w(viber), provider_message_ids: %w(m1))
          unknown = enqueue!(key: "rollback:unknown")
          unknown.update!(status: "unknown", reason: "worker_interrupted")

          enroll!(STATUS_COPY_CLASS, "legacy") # the rollback

          with_delivery { notifications.recover_pending! }

          assert_equal "pending", pending.reload.status, "never-attempted work may be requeued"
          assert_equal "unknown", claimed.reload.status, "an abandoned claim becomes uncertain, never pending"
          assert_equal "worker_interrupted", claimed.reason
          assert_equal "accepted", accepted.reload.status, "an accepted send is never resent"
          assert_equal %w(m1), accepted.provider_message_ids
          assert_equal "unknown", unknown.reload.status, "an uncertain record is never reset to clean a dashboard"
          assert_empty @client.calls, "recovery must not itself contact the provider"

          # And the one piece of work that WAS in flight still completes — on
          # the legacy body, because that is what the rollback selected.
          with_delivery { notifications.dispatch!(pending.reload) }

          assert_equal "accepted", pending.reload.status
          assert_equal 0, messaging::Intent.where(organization: @organization).count
        end

        # A STOP is the citizen's, not the feature's. Rolling the feature back
        # must not hand the provider's refusal back to the sender.
        test "rollback does not clear a provider STOP" do
          %w(viber whatsapp).each do |channel|
            messaging::TransportSuppression.ingest!(organization: @organization, provider: "infobip", channel:,
                                                    destination: { kind: "phone", value: "+38765111001" },
                                                    reason: "provider_opt_out", source: "provider_webhook", user: @author)
          end
          enroll!(STATUS_COPY_CLASS, "compatibility")
          enroll!(STATUS_COPY_CLASS, "legacy") # the rollback

          assert Decidim::Bih::TopicPreferences.enabled?(@author, topic: :report_updates)

          notification = enqueue!(key: "rollback:stopped")
          with_delivery { notifications.dispatch!(notification) }

          assert_empty @client.calls, "the legacy body must honour the STOP the routed body honoured"
          assert_equal "skipped", notification.reload.status
        end

        # The kill switch is the other half of G2 and is scoped independently:
        # it must be revertible on its own, without touching the mode.
        test "the dispatch kill switch rolls back on its own, leaving the mode where it was" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          disable_dispatch!(STATUS_COPY_CLASS)

          refute messaging::Enrollment.dispatch_enabled?(organization: @organization, message_class: STATUS_COPY_CLASS)

          Decidim::Bih::Setting.put(@organization, messaging::Modes::NAMESPACE,
                                    "dispatch_disabled.#{STATUS_COPY_CLASS}", false)

          assert messaging::Enrollment.dispatch_enabled?(organization: @organization, message_class: STATUS_COPY_CLASS)
          assert_equal :compatibility,
                       messaging::Enrollment.mode(organization: @organization, message_class: STATUS_COPY_CLASS)

          notification = enqueue!(key: "rollback:reenabled")
          with_delivery { notifications.dispatch!(notification) }

          assert_equal "accepted", notification.reload.status
          assert_equal 1, messaging::Intent.where(organization: @organization).count
        end
      end
    end
  end
end
