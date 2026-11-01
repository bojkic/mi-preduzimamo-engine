# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/topic_preferences"
require_relative "../../../../../app/services/decidim/bih/messaging/settings_catalogue"

module Decidim
  module Bih
    module Messaging
      class SettingsCatalogueTest < Minitest::Test
        def test_only_the_four_topic_choices_are_in_the_citizen_catalogue
          assert_equal(%w(report_updates community_news platform_news neighborhood_info),
                       SettingsCatalogue.for(nil).map { |row| row[:id].to_s })
          assert(SettingsCatalogue::ROWS.all? { |row| row[:kind] == :bool && !row.has_key?(:channel) })
        end

        def test_privacy_staff_platform_and_device_settings_are_not_topic_choices
          ids = SettingsCatalogue.writable(nil).map { |row| row[:id] }
          [:direct_messages, :email_on_moderations, :email_on_assigned_proposals,
           :bells_own, :bells_followed, :urgent_bell, :push_this_device].each do |id|
            refute_includes ids, id
          end
        end
      end
    end
  end
end
