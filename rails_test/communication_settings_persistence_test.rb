# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class CommunicationSettingsPersistenceTest < ActiveSupport::TestCase
        test "retired core command cannot write any removed preference" do
          user = FactoryBot.create(:user, :confirmed, organization: create_organization)
          before = user.reload.attributes.deep_dup
          form = Decidim::NotificationsSettingsForm.from_params(
            notifications_from_own_activity: "0", notifications_from_followed: "0",
            notifications_sending_frequency: "none", newsletter_notifications: "0",
            notification_settings: { "mi_report_updates_viber" => "0" }
          ).with_context(current_user: user)
          rejected = false
          Decidim::UpdateNotificationsSettings.call(form) { on(:invalid) { rejected = true } }
          assert rejected
          assert_equal before, user.reload.attributes
        end
      end
    end
  end
end
