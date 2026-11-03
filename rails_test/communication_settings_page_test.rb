# frozen_string_literal: true

require "test_helper"
require "capybara"

module Decidim
  module Bih
    class CommunicationSettingsPageTest < ActionDispatch::IntegrationTest
      include ::Devise::Test::IntegrationHelpers
      PAGE = Decidim::Bih.public_path("moj-nalog/poruke")
      PRIVACY = Decidim::Bih.public_path("moj-nalog/privatnost-poruka")

      setup do
        @organization = create_organization
        host! @organization.host
        @user = FactoryBot.create(:user, :confirmed, organization: @organization)
      end

      test "settings require an account in the current organization" do
        get PAGE
        assert_redirected_to "/sr/users/sign_in?#{{ redirect_url: PAGE }.to_query}"
        sign_in FactoryBot.create(:user, :confirmed, organization: create_organization)
        patch PAGE, params: { communication_settings: { community_news: "0" }, user_id: @user.id }
        assert_response :redirect
        assert TopicPreferences.enabled?(@user.reload, topic: :community_news)
        patch PRIVACY, params: { message_privacy: { allow_public_contact: "0" }, user_id: @user.id }
        assert_response :redirect
        assert_equal "all", @user.reload.direct_message_types
      end

      test "only four topics are selectable and all start on" do
        sign_in @user
        get PAGE
        assert_response :success
        assert_select "[data-communication-form] input[type=checkbox]", count: 4
        assert_select "[data-communication-form] input[type=checkbox][checked]", count: 4
        assert_select "input[type=radio]", count: 0
        assert_select "[data-setting-section=external]", count: 0
        assert_select "[data-setting-requested], [data-setting-origin]", count: 0
        assert_select "[data-setting-section=inapp] input", count: 0
        assert_select "[data-setting-section=contact] a", minimum: 1
        TopicPreferences::TOPICS.each do |topic|
          assert_select "label[for=communication_settings_#{topic}]", count: 1
        end
      end

      test "one topic choice changes only the current account and topic and round trips" do
        sign_in @user
        other = FactoryBot.create(:user, :confirmed, organization: @organization)
        @user.update!(notification_settings: { "subscriptions" => { "device" => { "auth" => "key" } } })
        before = @user.notification_settings.deep_dup
        patch PAGE, params: { communication_settings: { report_updates: "0" }, user_id: other.id }
        assert_redirected_to PAGE
        assert_not TopicPreferences.enabled?(@user.reload, topic: :report_updates)
        assert TopicPreferences.enabled?(@user, topic: :community_news)
        assert TopicPreferences.enabled?(other.reload, topic: :report_updates)
        assert_equal before, @user.notification_settings
        get PAGE
        assert_select "#communication_settings_report_updates[checked]", count: 0
        assert_select "[data-communication-form] input[type=checkbox][checked]", count: 3
      end

      test "unchecking every topic preserves platform inbox and device subscriptions" do
        sign_in @user
        before = @user.notification_settings.deep_dup
        patch PAGE, params: { communication_settings: TopicPreferences::TOPICS.index_with { "0" } }
        assert_redirected_to PAGE
        TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(@user, topic:) }
        assert_equal "all", @user.reload.notification_types
        assert_equal before, @user.notification_settings
      end

      test "obsolete forms and legacy screen cannot restore removed settings" do
        sign_in @user
        before = @user.attributes.slice("notification_settings", "notification_types", "notifications_sending_frequency")
        patch PAGE, params: { topic: "community_news", channel: "whatsapp", enabled: "0" }
        assert_response :unprocessable_entity
        put "/notifications_settings", params: { notifications_from_own_activity: "0", notifications_from_followed: "0",
                                                 newsletter_notifications: "0", notifications_sending_frequency: "none",
                                                 notification_settings: { mi_report_updates_viber: "0" } }
        assert_response :see_other
        assert_redirected_to PAGE
        assert_equal before, @user.reload.attributes.slice(*before.keys)
        assert TopicPreferences.enabled?(@user, topic: :platform_news)
        get "/notifications_settings", params: { legacy: "true" }
        assert_redirected_to PAGE
      end

      test "a stale matrix form is rejected visibly without claiming its choices were saved" do
        sign_in @user
        patch PAGE, params: { communication_settings: { report_updates_viber: "0", bells_own: "0" } }
        assert_response :unprocessable_entity
        assert_includes response.body, I18n.t("decidim.bih.communication_settings.screen_changed", locale: :sr)
        assert_select "[data-communication-form] input[type=checkbox]", count: 4
        assert TopicPreferences.enabled?(@user.reload, topic: :report_updates)
        assert_equal "all", @user.notification_types
      end

      test "a failed multi-topic save rolls back and preserves submitted values" do
        sign_in @user
        original = TopicPreferences.method(:set!)
        calls = 0
        writer = lambda do |user, **args|
          calls += 1
          raise ActiveRecord::RecordInvalid, user if calls == 2

          original.call(user, **args)
        end
        TopicPreferences.stub(:set!, writer) do
          patch PAGE, params: { communication_settings: { report_updates: "0", community_news: "0" } }
        end
        assert_response :unprocessable_entity
        assert TopicPreferences.enabled?(@user.reload, topic: :report_updates)
        assert TopicPreferences.enabled?(@user, topic: :community_news)
        assert_select "#communication_settings_report_updates[checked]", count: 0
        assert_select "#communication_settings_community_news[checked]", count: 0
      end

      test "DM privacy is separately editable without changing topics or staff controls" do
        sign_in @user
        patch PRIVACY, params: { message_privacy: { allow_public_contact: "0", email_on_assigned_proposals: "0",
                                                    email_on_moderations: "0" } }
        assert_redirected_to "#{Decidim::Bih.public_path("moj-nalog")}#privatnost-poruka"
        assert_equal "followed-only", @user.reload.direct_message_types
        assert_equal true, @user.email_on_assigned_proposals
        assert_equal true, @user.email_on_moderations
        TopicPreferences::TOPICS.each { |topic| assert TopicPreferences.enabled?(@user, topic:) }
        get Decidim::Bih.public_path("moj-nalog")
        assert_response :success
        assert_select "#mi-allow-public-contact", count: 1
        assert_select "[data-staff-notification-settings]", count: 0
      end

      test "staff settings stay separate and an omitted field is preserved" do
        @user.update!(admin: true)
        sign_in @user
        patch PRIVACY, params: { message_privacy: { email_on_assigned_proposals: "0" } }
        assert_response :redirect
        assert_equal false, @user.reload.email_on_assigned_proposals
        assert_equal true, @user.email_on_moderations
        assert_equal "all", @user.direct_message_types
      end

      test "push setup is outside the topic save and does not create subscriptions" do
        sign_in @user
        assert_no_difference -> { @user.reload.notifications_subscriptions.size } do
          patch PAGE, params: { communication_settings: { push_this_device: "1" } }
        end
        get PAGE
        assert_select "[data-push-section]", count: 1
        assert_select "[data-communication-form] [data-push-section]", count: 0
        assert_select "button[data-push-disable]", count: 0
      end

      test "explicit self-test is scoped and rate limited" do
        sign_in @user
        attempts = []
        Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
          AccountNotifications.stub(:preview_test, { eligible: true, channels: ["viber"], reasons: {} }) do
            AccountNotifications.stub(:enqueue_test!, ->(**args) { attempts << args }) do
              post "#{PAGE}/proba", params: { channel: "viber", user_id: 999_999 }
              assert_response :redirect
              post "#{PAGE}/proba", params: { channel: "viber" }
              assert_response :too_many_requests
            end
          end
        end
        assert_equal 1, attempts.length
        assert_equal @user.id, attempts.first[:user].id
      end
    end
  end
end
