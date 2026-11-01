# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/admin/community_queue_context"

class CommunityQueueContextTest < Minitest::Test
  Context = Decidim::Bih::Admin::CommunityQueueContext

  def test_preserves_only_bounded_queue_pages
    context = Context.new("projects_page" => "3", "needs_page" => "0", "offers_page" => "1000000",
                          "return_to" => "https://elsewhere.example/review", "decision" => "recognize")

    assert_equal 3, context.page(:projects_page)
    assert_equal 1, context.page(:needs_page)
    assert_equal Context::MAX_PAGE, context.page(:offers_page)
    assert_equal({ "projects_page" => 3, "offers_page" => Context::MAX_PAGE }, context.to_h)
  end

  def test_rejects_non_scalar_and_non_numeric_page_values
    context = Context.new(projects_page: ["2"], needs_page: "-3", offers_page: "1?next=/admin")

    assert_equal({}, context.to_h)
  end

  def test_moves_from_empty_last_page_to_remaining_queue_page
    context = Context.new("projects_page" => "3", "needs_page" => "2")

    context.clamp_to_count(:projects_page, count: 25, per: 25)

    assert_equal({ "needs_page" => 2 }, context.to_h)
  end
end
