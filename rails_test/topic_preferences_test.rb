# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class TopicPreferencesTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "missing choices default on without creating preference or history rows" do
          assert_no_difference ["Messaging::Preference.count", "Messaging::PreferenceChange.count"] do
            TopicPreferences::TOPICS.each { |topic| assert TopicPreferences.enabled?(@user, topic:) }
          end
        end

        test "registration all off persists exactly four account choices atomically" do
          TopicPreferences.set_all!(@user, enabled: false)
          assert_equal 4, Messaging::Preference.where(user: @user).count
          assert_equal 4, Messaging::PreferenceChange.where(user: @user).count
          assert Messaging::Preference.where(user: @user).all?(&:blocked?)
          assert Messaging::Preference.where(user: @user).all?(&:personal_choice?)
          assert(Messaging::PreferenceChange.where(user: @user).all? { |event| event.channel == "topic" })
        end

        test "explicit all on records citizen choice instead of inheriting silently" do
          TopicPreferences.set_all!(@user, enabled: true)
          assert_equal 4, Messaging::Preference.where(user: @user, source: "account", state: "allowed").count
        end

        test "changing one topic preserves the other three and stores no matrix" do
          TopicPreferences.set_all!(@user, enabled: true)
          TopicPreferences.set!(@user, topic: :city_service_alerts, enabled: false)
          assert_not TopicPreferences.enabled?(@user, topic: :neighborhood_info)
          assert TopicPreferences.enabled?(@user, topic: :report_updates)
          assert TopicPreferences.enabled?(@user, topic: :community_news)
          assert TopicPreferences.enabled?(@user, topic: :platform_news)
          assert_not_includes Messaging::Preference.column_names, "channel"
          assert_empty @user.reload.notification_settings.keys.grep(/mi_.*_(viber|whatsapp|messenger|instagram)/)
        end

        test "repeat identical saves preserve history and previous state records an actual change" do
          TopicPreferences.set!(@user, topic: :report_updates, enabled: false)
          assert_no_difference "Messaging::PreferenceChange.count" do
            TopicPreferences.set!(@user, topic: :report_updates, enabled: false)
          end
          TopicPreferences.set!(@user, topic: :report_updates, enabled: true)
          event = Messaging::PreferenceChange.where(user: @user).order(:id).last
          assert_equal "blocked", event.previous_state
          assert_equal "allowed", event.new_state
        end

        test "history failure rolls back every topic in a whole page write" do
          TopicPreferences.set_all!(@user, enabled: true)
          assert_raises(ActiveRecord::RecordInvalid) do
            Messaging::PreferenceChange.stub(:create!, ->(**) { raise ActiveRecord::RecordInvalid }) do
              TopicPreferences.set_all!(@user, enabled: false)
            end
          end
          assert Messaging::Preference.where(user: @user).all?(&:allowed?)
        end

        test "enabling topics leaves device subscriptions and provider blocks unchanged" do
          @user.update!(notification_settings: { "subscriptions" => { "device" => { "auth" => "test" } } })
          suppression = Messaging::Suppression.create!(
            organization: @organization, user: @user, provider: "infobip", channel: "viber",
            destination_kind: "phone", destination_digest: "a" * 64, reason: "provider_opt_out",
            source: "provider_webhook", suppressed_at: Time.current
          )
          TopicPreferences.set_all!(@user, enabled: true)
          assert_predicate suppression.reload, :active?
          assert_equal({ "device" => { "auth" => "test" } }, @user.reload.notification_settings["subscriptions"])
          assert_raises(ArgumentError) { TopicPreferences.set!(@user, topic: :report_updates, enabled: false, source: "provider_opt_out") }
        end
      end
    end
  end
end
