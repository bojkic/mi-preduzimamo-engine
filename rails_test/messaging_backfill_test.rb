# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class MessagingBackfillTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "retired backfill reports canonical counts without mutating" do
          TopicPreferences.set_all!(@user, enabled: false)
          assert_no_difference ["Messaging::Preference.count", "Messaging::PreferenceChange.count", "Setting.count"] do
            report = Messaging::Backfill.new(organization: @organization).run!
            assert_equal 4, report.already_current
            assert_equal 0, report.imported
            assert_not report.apply
          end
        end

        test "old apply command cannot recreate the removed matrix or overwrite topics" do
          TopicPreferences.set_all!(@user, enabled: false)
          assert_raises(ArgumentError) { Messaging::Backfill.new(organization: @organization, apply: true).run! }
          assert Messaging::Preference.where(user: @user).all?(&:blocked?)
        end
      end
    end
  end
end
