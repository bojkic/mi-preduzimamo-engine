# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportRoutingGuidesTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
        end
        test "unknown recipients cannot be approved through guidance" do
          guide = ReportRoutingGuide.new(organization: @organization, approved_by: @admin, key: 'parking', title: 'Parking', body_sr: 'Uputstvo', active: true, categories: [], approved_recipient_keys: ['invented'])
          refute guide.valid?
          assert guide.errors[:approved_recipient_keys].present?
        end
        test "edits increment the freshness version" do
          guide = ReportRoutingGuide.create!(organization: @organization, approved_by: @admin, key: 'parking', title: 'Parking', body_sr: 'Ne zaključuj da je parkiranje dozvoljeno zato što nema znaka.')
          assert_equal 1, guide.version
          guide.update!(body_sr: 'Svako novo upućivanje traži pregled.')
          assert_equal 2, guide.reload.version
        end
      end
    end
  end
end
