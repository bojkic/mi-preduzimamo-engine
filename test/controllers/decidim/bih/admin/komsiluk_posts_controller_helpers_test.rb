# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/numeric/time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require_relative "../../../../../app/services/decidim/bih/komsiluk/post_moderation"

module Decidim
  module Bih
    module Admin
      # Lifecycle restoration survives moving decisions into a transactional
      # service. Queue behavior is exercised against real rows in the host suite.
      class KomsilukPostsControllerHelpersTest < Minitest::Test
        Post = Struct.new(:closed_at, :expires_at, :details, keyword_init: true)

        def test_closed_post_stays_closed_even_after_its_expiry
          assert_equal "closed", restored(closed_at: Time.current, expires_at: 1.day.ago)
        end

        def test_elapsed_expiry_is_enforced_before_the_scheduled_job
          assert_equal "expired", restored(expires_at: 1.second.ago)
        end

        def test_prior_expired_state_is_preserved_without_an_expiry_timestamp
          assert_equal "expired", restored(details: { "moderation" => { "previous_status" => "expired" } })
        end

        def test_future_notice_can_be_restored_to_open
          assert_equal "open", restored(expires_at: 1.day.from_now)
        end

        private

        def restored(closed_at: nil, expires_at: nil, details: {})
          post = Post.new(closed_at:, expires_at:, details:)
          Komsiluk::PostModeration.new(post:, actor: nil, organization: nil).send(:restored_status)
        end
      end
    end
  end
end
