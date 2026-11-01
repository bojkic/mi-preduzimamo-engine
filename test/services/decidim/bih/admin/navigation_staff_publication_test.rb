# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/admin/navigation"

class NavigationStaffPublicationTest < Minitest::Test
  class Routes
    def method_missing(name, *args, **kwargs)
      return "/admin/bih/#{name}" if name.to_s.end_with?("_path")

      super
    end

    def respond_to_missing?(name, include_private = false)
      name.to_s.end_with?("_path") || super
    end
  end

  class View
    def decidim_admin_bih = Routes.new
    def bih_allowed?(permission) = permission == :broadcast_preview
  end

  class CommunityView < View
    def bih_allowed?(permission) = [:partner_profiles_manage, :community_contributions_read].include?(permission)
  end

  def test_broadcaster_sees_direct_publication_without_forbidden_board_queue
    items = Decidim::Bih::Admin::Navigation.items(view_context: View.new)
    ids = items.map { |item| item[:id] }

    assert_includes ids, "staff_publication"
    refute_includes ids, "komsiluk_posts"
    refute_includes ids, "broadcasts"
    assert_equal "/admin/bih/new_admin_bih_board_notice_path", items.find { |item| item[:id] == "staff_publication" }[:url]
  end

  def test_publication_breadcrumb_resolves_for_broadcaster
    crumbs = Decidim::Bih::Admin::Navigation.breadcrumbs(view_context: View.new, current_item: :staff_publication)

    assert_equal "staff_publication", crumbs.last[:id]
    assert_equal "/admin/bih/new_admin_bih_board_notice_path", crumbs.last[:url]
  end

  def test_organization_review_sits_with_daily_community_work
    items = Decidim::Bih::Admin::Navigation.items(view_context: CommunityView.new)

    assert_equal "daily", items.find { |item| item[:id] == "partner_profiles" }[:area_id]
    assert_equal "daily", items.find { |item| item[:id] == "community_contributions" }[:area_id]
  end
end
