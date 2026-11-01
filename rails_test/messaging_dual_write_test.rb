# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class MessagingDualWriteTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "legacy writer API updates one canonical topic and never a matrix" do
          Messaging::PreferenceMirror.record!(user: @user, topic: :report_updates, channel: :viber,
                                              enabled: false, source: "account")
          assert_not TopicPreferences.enabled?(@user, topic: :report_updates)
          assert_equal 1, Messaging::Preference.where(user: @user).count
          assert_empty @user.reload.notification_settings
        end

        test "old core form merge is absorbed into canonical topics while subscriptions survive" do
          subscriptions = { "device" => { "auth" => "test" } }
          @user.update!(notification_settings: { "subscriptions" => subscriptions, "mi_community_news_viber" => false })
          @user.with_lock do
            Messaging::PreferenceMirror.mirror_changes!(user: @user, previous: {}, default_source: "account")
          end
          assert_not TopicPreferences.enabled?(@user, topic: :community_news)
          assert_equal({ "subscriptions" => subscriptions }, @user.reload.notification_settings)
        end

        test "legacy provider mirror cannot write a channel refusal as a whole topic choice" do
          assert_no_difference ["Messaging::Preference.count", "Messaging::PreferenceChange.count"] do
            Messaging::PreferenceMirror.record!(user: @user, topic: :report_updates, channel: :viber,
                                                enabled: false, source: "provider_opt_out")
          end
          assert TopicPreferences.enabled?(@user, topic: :report_updates)
        end
      end
    end
  end
end
