# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Canonical neighborhood permission and automatic external candidates,
      # while inbox, membership, deadlines and rollout guards remain separate.
      class MessagingRouterCityAlertsTest < ActiveSupport::TestCase
        CITY_ALERT = "city.service_alert_viber"
        BROADCAST = "komsiluk.area_broadcast"
        URGENT_POST = "komsiluk.urgent_post"

        def routing = Decidim::Bih::Messaging::ExternalCopyRouting

        def enrollment = Decidim::Bih::Messaging::Enrollment

        def preferences = Decidim::Bih::NotificationPreferences

        setup do
          @organization = create_organization
          @area = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id, kind: "komsiluk",
            slug: "k-#{SecureRandom.hex(4)}", name: { "sr" => "Test komšiluk" }
          )
          @published = []
        end

        def enroll!(message_class, mode = "compatibility")
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                    "mode.#{message_class}", mode)
        end

        def citizen_with(settings = {})
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          settings.each do |topic, channels|
            channels.each { |channel, on| preferences.set!(user, topic:, channel:, enabled: on) }
          end
          Decidim::Bih::EmailConfirmation.mark_confirmed!(user)
          with_phone!(user)
        end

        # A stored, verified number. Without one the policy answers
        # `destination_unknown` for every phone channel — correctly, and for the
        # same reason `AccountNotifications.preview` answers
        # `verified_phone_required`.
        def with_phone!(user)
          phone = format("+3876%07d", user.id)
          Decidim::Authorization.find_or_create_by!(user:, name: "sms") do |grant|
            grant.unique_id = Decidim::Bih::SmsAuthorization.unique_id_for(phone)
            grant.granted_at = Time.current
          end
          Decidim::Bih::CitizenPhone.store!(user, phone)
          user
        end

        def routed_channels(user, message_class: CITY_ALERT, requested: %w(viber), deadline_at: nil)
          routing.decide(user:, organization: @organization, message_class:,
                         requested_channels: requested, deadline_at:, dedup_key: "harness").channels
        end

        # ---- the channel decision itself --------------------------------------

        test "default on and explicit neighborhood refusal are shared by all channel readers" do
          enroll!(CITY_ALERT)

          assert_equal %w(viber), routed_channels(citizen_with(city_service_alerts: { viber: true }))
          assert_equal %w(viber), routed_channels(citizen_with)
          assert_empty routed_channels(citizen_with(city_service_alerts: { viber: false }))
        end

        test "the enqueue selector and delivery reader both default on" do
          enroll!(CITY_ALERT)
          silent = citizen_with

          assert preferences.enabled?(silent, topic: :city_service_alerts, channel: :viber,
                                              fallback_key: preferences::LEGACY_LOCAL_ALERTS_KEY),
                 "the SELECTION reader is default-allowed and still enqueues this citizen"
          assert_equal %w(viber), routed_channels(silent)
        end

        test "an unenrolled class cannot be routed however the flag is set, so the urgent board keeps its legacy body" do
          enroll!(URGENT_POST, "target")

          refute enrollment.routes?(organization: @organization, message_class: URGENT_POST)
          refute routing.decide(user: citizen_with, organization: @organization, message_class: URGENT_POST,
                                requested_channels: %w(viber)).routed?
        end

        test "dispatch_disabled returns the caller to its legacy body rather than silencing it" do
          enroll!(CITY_ALERT)
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                    "dispatch_disabled.#{CITY_ALERT}", true)

          decision = routing.decide(user: citizen_with(city_service_alerts: { viber: true }),
                                    organization: @organization, message_class: CITY_ALERT,
                                    requested_channels: %w(viber))

          refute_predicate decision, :routed?
          assert_nil decision.channels, "a rollback must hand the caller nothing, not an empty list"
        end

        test "an elapsed deadline produces no channel rather than a late notice" do
          enroll!(CITY_ALERT)
          citizen = citizen_with(city_service_alerts: { viber: true })

          assert_empty routed_channels(citizen, deadline_at: 1.minute.ago)
          assert_equal %w(viber), routed_channels(citizen, deadline_at: 1.hour.from_now)
        end

        test "a citizen with no verified number is not claimed reachable by the plan" do
          enroll!(CITY_ALERT)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          preferences.set!(user, topic: :city_service_alerts, channel: :viber, enabled: true)

          assert_empty routed_channels(user)
        end

        # ---- the broadcast, end to end through the real job --------------------

        def broadcast!(channels)
          Decidim::Bih::Broadcast.create!(organization: @organization, area: @area, message: "Obavještenje",
                                          channels: channels.join(","), recipients_count: 1)
        end

        # The bell leg publishes a Decidim event, which is an enqueued job in
        # this harness rather than a row. Spying on the publish keeps "the bell
        # still rang" an assertion instead of an inference.
        def perform_broadcast(user, broadcast)
          published = @published
          spy = ->(**attributes) { published << attributes }
          Decidim::EventsManager.stub(:publish, spy) do
            Decidim::Bih::BroadcastNotificationJob.perform_now(
              { organization_id: @organization.id, user_ids: [user.id], broadcast_id: broadcast.id }
            )
          end
        end

        def payload_channels(user)
          Decidim::Bih::AccountNotification.where(user:).last&.payload&.fetch("channels")
        end

        test "legacy and enrolled broadcasts expand the automatic toggle to the same eligible email" do
          legacy_citizen = citizen_with
          Decidim::Bih::Messaging::BroadcastChannels.stub(:for, ["email"]) do
            assert_difference "Decidim::Bih::AccountNotification.count", 1 do
              perform_broadcast(legacy_citizen, broadcast!(%w(bell viber)))
            end
            enroll!(BROADCAST)
            routed_citizen = citizen_with
            perform_broadcast(routed_citizen, broadcast!(%w(bell whatsapp)))
            assert_equal ["email"], payload_channels(legacy_citizen)
            assert_equal ["email"], payload_channels(routed_citizen)
          end
        end

        test "an explicit neighborhood refusal leaves a skipped intent and preserves the inbox" do
          enroll!(BROADCAST)
          user = citizen_with(neighborhood_info: { viber: false })
          Decidim::Bih::Messaging::BroadcastChannels.stub(:for, ["email"]) do
            perform_broadcast(user, broadcast!(%w(bell viber)))
          end
          notification = Decidim::Bih::AccountNotification.where(user:).last
          assert_empty notification.payload.fetch("channels")
          assert_no_difference "ActionMailer::Base.deliveries.size" do
            Decidim::Bih::AccountNotifications.dispatch!(notification)
          end
          assert_equal "skipped", notification.reload.status
          assert_equal 1, @published.size
        end

        test "automatic broadcast choices cannot add an unapproved provider" do
          enroll!(BROADCAST)
          user = citizen_with
          Decidim::Bih::Messaging::BroadcastChannels.stub(:for, ["email"]) do
            perform_broadcast(user, broadcast!(%w(bell viber whatsapp messenger)))
          end
          assert_equal ["email"], payload_channels(user)
        end

        test "disabling community news does not disable a neighborhood broadcast" do
          enroll!(BROADCAST)
          user = citizen_with(community_news: { viber: false })
          Decidim::Bih::Messaging::BroadcastChannels.stub(:for, ["email"]) do
            perform_broadcast(user, broadcast!(%w(bell viber)))
          end
          assert_equal ["email"], payload_channels(user)
          assert_equal 1, @published.size
        end

        test "an enrolled inbox-only broadcast still creates the inbox event without proactive copies" do
          enroll!(BROADCAST)
          user = citizen_with(neighborhood_info: { viber: false })
          assert_no_difference "Decidim::Bih::AccountNotification.count" do
            perform_broadcast(user, broadcast!(%w(bell)))
          end
          assert_equal 1, @published.size
        end
      end
    end
  end
end
