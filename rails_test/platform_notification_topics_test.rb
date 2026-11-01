# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class PlatformNotificationTopicsTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization, notification_types: "none")
          Decidim::Bih::TopicPreferences.set_all!(@user, enabled: false)
        end

        test "disabled proactive topics and old notification scope cannot hide affected-user inbox events" do
          assert_enqueued_with(job: Decidim::NotificationGeneratorForRecipientJob) do
            generator([], [@user]).generate
          end
        end

        test "disabled proactive topics and old notification scope cannot hide followed inbox events" do
          assert_enqueued_with(job: Decidim::NotificationGeneratorForRecipientJob) do
            generator([@user], []).generate
          end
        end

        test "overlapping affected and followed audiences enqueue only one inbox notification" do
          assert_enqueued_jobs 1, only: Decidim::NotificationGeneratorForRecipientJob do
            generator([@user], [@user, @user]).generate
          end
        end

        test "always-on inbox still respects resource access" do
          @user.define_singleton_method(:can_participate?) { |_recipient| false }
          assert_no_enqueued_jobs { generator([], [@user]).generate }
        ensure
          @user.singleton_class.remove_method(:can_participate?)
        end

        test "turning off a topic never removes already-created inbox items" do
          notification = Decidim::Notification.create!(user: @user, resource: @user,
                                                       event_name: "decidim.events.bih.komsiluk_post",
                                                       event_class: "Decidim::Bih::KomsilukPostEvent",
                                                       extra: { "received_as" => "affected_user" })
          Decidim::Bih::TopicPreferences.set_all!(@user, enabled: false)
          assert Decidim::Notification.exists?(notification.id)
        end

        private

        def generator(followers, affected)
          Decidim::NotificationGenerator.new("decidim.events.bih.komsiluk_post", Decidim::Bih::KomsilukPostEvent,
                                             @user, followers, affected, {})
        end
      end
    end
  end
end
