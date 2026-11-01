# frozen_string_literal: true

require "test_helper"
require "minitest/mock"
require_relative "../../../../app/services/decidim/bih/komsiluk/notice_publishing"
require_relative "../../../../app/services/decidim/bih/komsiluk_post_notification_service"

module Decidim
  module Bih
    class KomsilukPostNotificationServiceTest < Minitest::Test
      Post = Struct.new(:id, :origin, :category, keyword_init: true)

      def test_uncaptured_legacy_notices_never_create_a_new_publication_even_for_urgent_categories
        Komsiluk::NoticePublishing.stub(:publish!, ->(**) { flunk "Legacy notices cannot capture a new audience" }) do
          %w(general lost_pet safety).each do |category|
            post = Post.new(id: 321, origin: "legacy", category:)
            assert_nil KomsilukPostNotificationService.call(post:, board_url: board_url)
            assert_nil KomsilukPostNotificationService.call(post:, board_url: board_url,
                                                            delivery_identity: "old:identity", delivery_context: { event_id: 9 })
          end
        end
      end

      def test_all_new_notice_origins_and_categories_use_the_durable_publication_boundary
        captured = []
        capture = lambda do |**arguments|
          captured << arguments
          "captured"
        end
        Komsiluk::NoticePublishing.stub(:publish!, capture) do
          %w(citizen staff city_service).product(%w(general lost_pet safety)).each do |origin, category|
            post = Post.new(id: 321, origin:, category:)
            assert_equal "captured", KomsilukPostNotificationService.call(post:, board_url: board_url)
            assert_equal({ post:, identity: nil, expires_at: nil, context: {} }, captured.last)
          end
        end
      end

      def test_source_identity_revision_and_expiry_reach_the_publication_capture_unchanged
        post = Post.new(id: 321, origin: "city_service", category: "safety")
        expiry = Time.utc(2026, 9, 25, 20)
        context = { event_id: 22, event_revision: "reviewed-revision", notice_update: true }
        captured = []
        Komsiluk::NoticePublishing.stub(:publish!, ->(**arguments) { captured << arguments }) do
          KomsilukPostNotificationService.call(post:, board_url: board_url, proactive_delivery: false,
                                               delivery_identity: "incident:revision", delivery_expires_at: expiry,
                                               delivery_context: context)
        end
        assert_equal [{ post:, identity: "incident:revision", expires_at: expiry, context: }], captured
      end

      private

      def board_url
        "https://mi.example.test/biceriseno/komsiluk-board"
      end
    end
  end
end
