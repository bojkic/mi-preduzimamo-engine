# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require "decidim/bih"
require_relative "../../../../app/helpers/decidim/bih/komsiluk_board_helper"

class KomsilukBoardPublicSourceTest < Minitest::Test
  Post = Struct.new(:id, :origin, :details)

  class ViewProbe
    include Decidim::Bih::KomsilukBoardHelper

    def current_organization = :current_tenant
  end

  def teardown
    Decidim::Bih.komsiluk_notice_public_source_provider = nil
  end

  def test_unconfigured_linked_source_is_hidden_until_current_visibility_can_be_checked
    state = ViewProbe.new.board_public_source_state(linked_post)

    assert_equal({ updating: true, url: nil }, state)
  end

  def test_current_source_exposes_only_a_safe_current_path
    Decidim::Bih.komsiluk_notice_public_source_provider = lambda do |organization:, post:|
      assert_equal :current_tenant, organization
      assert_equal 5, post.id
      { updating: false, url: "/biceriseno/prijave/123" }
    end

    assert_equal({ updating: false, url: "/biceriseno/prijave/123" }, ViewProbe.new.board_public_source_state(linked_post))
  end

  def test_unsafe_link_is_rejected_even_when_adapter_returns_it
    Decidim::Bih.komsiluk_notice_public_source_provider = ->(**) { { updating: false, url: "//another.example/path" } }

    assert_equal({ updating: true, url: nil }, ViewProbe.new.board_public_source_state(linked_post))
  end

  def test_backslash_and_encoded_separator_links_are_rejected
    ["/\\another.example/path", "/biceriseno\\evil", "/%2fexample.test", "/%5cexample.test", "/biceriseno/../admin", "/biceriseno/has space"].each do |path|
      Decidim::Bih.komsiluk_notice_public_source_provider = ->(**) { { updating: false, url: path } }

      assert_equal({ updating: true, url: nil }, ViewProbe.new.board_public_source_state(linked_post), path)
    end
  end

  def test_citizen_post_never_calls_source_adapter
    Decidim::Bih.komsiluk_notice_public_source_provider = ->(**) { raise "unexpected call" }

    assert_equal({ updating: false, url: nil }, ViewProbe.new.board_public_source_state(Post.new(6, "citizen", {})))
  end

  private

  def linked_post
    Post.new(5, "staff", { "source_record" => { "kind" => "report", "id" => 123 } })
  end
end
