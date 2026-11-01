# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class PublicSurfacesTest < Minitest::Test
  def test_required_public_surface_manifest_is_unique_and_reviewable
    surfaces = Decidim::Bih.required_public_surface_manifest(mount_path: "/moja-platforma")
    ids = surfaces.map { |surface| surface.fetch(:id) }

    assert_equal ids.uniq, ids
    assert_includes ids, "reports.new"
    assert_includes ids, "community_hub.show"
    assert_includes ids, "mz_directory.index"
    assert_includes ids, "web_chat.create"
    assert(surfaces.all? { |surface| surface.fetch(:methods).is_a?(Array) })
    assert(surfaces.all? { |surface| surface.fetch(:host_review_flags).is_a?(Array) })
    assert(surfaces.all? { |surface| surface.fetch(:privacy_boundary).to_s.include?(" ") })
  end

  def test_required_public_surface_manifest_has_second_host_review_metadata
    surfaces = Decidim::Bih.required_public_surface_manifest(mount_path: "/moja-platforma")

    assert(surfaces.all? { |surface| surface.fetch(:owner) == "engine" })
    assert(surfaces.all? { |surface| valid_lifecycle?(surface.fetch(:lifecycle)) })
    assert(surfaces.all? { |surface| surface.has_key?(:public_nav) })
    assert(surfaces.all? { |surface| surface.has_key?(:branding_review_required) })
    assert(surfaces.all? { |surface| surface.has_key?(:stable_compatibility_path) })
    assert(surfaces.none? { |surface| surface.to_s.include?("/biceriseno") })
  end

  def test_required_public_surface_manifest_expands_custom_mount_paths
    surfaces = Decidim::Bih.required_public_surface_manifest(mount_path: "/moja-platforma")
    root = surfaces.find { |surface| surface.fetch(:id) == "reports.root" }
    reports = surfaces.find { |surface| surface.fetch(:id) == "reports.new" }
    map = surfaces.find { |surface| surface.fetch(:id) == "reports_map.show" }
    mz_detail = surfaces.find { |surface| surface.fetch(:id) == "mz_directory.show" }

    assert_equal ["/moja-platforma"], root.fetch(:paths)
    assert_equal ["/moja-platforma/prijave/new"], reports.fetch(:paths)
    assert_equal ["/moja-platforma/mapa", "/moja-platforma/mapa.json"], map.fetch(:paths)
    assert_equal(
      ["/moja-platforma/mjesne-zajednice/:slug", "/moja-platforma/mjesne-zajednice/:slug.json"],
      mz_detail.fetch(:paths)
    )
  end

  def test_required_public_surface_manifest_expands_root_mount_without_blank_path
    surfaces = Decidim::Bih.required_public_surface_manifest(mount_path: "/")
    root = surfaces.find { |surface| surface.fetch(:id) == "reports.root" }
    chat = surfaces.find { |surface| surface.fetch(:id) == "web_chat.create" }

    assert_equal ["/"], root.fetch(:paths)
    assert_equal ["/chat"], chat.fetch(:paths)
  end

  def test_private_and_write_surfaces_are_classified
    surfaces = Decidim::Bih.required_public_surface_manifest
    wallet = surfaces.find { |surface| surface.fetch(:id) == "wallet.show" }
    komsiluk = surfaces.find { |surface| surface.fetch(:id) == "komsiluk.edit" }
    chat = surfaces.find { |surface| surface.fetch(:id) == "web_chat.create" }

    assert_equal "private_account", wallet.fetch(:lifecycle)
    assert_equal "private_account", komsiluk.fetch(:lifecycle)
    assert_equal "write_endpoint", chat.fetch(:lifecycle)
    assert_equal false, wallet.fetch(:public_nav)
    assert_equal false, komsiluk.fetch(:public_nav)
    assert_equal false, chat.fetch(:public_nav)
  end

  def test_required_public_surface_manifest_tracks_public_menu_i18n_keys
    surfaces = Decidim::Bih.required_public_surface_manifest
    menu_keys = surfaces.filter_map { |surface| surface[:menu_i18n_key] }

    assert_includes menu_keys, "decidim.bih.menu.reports"
    assert_includes menu_keys, "decidim.bih.menu.reports_map"
    assert_includes menu_keys, "decidim.bih.menu.reports_tracker"
    assert_includes menu_keys, "decidim.bih.menu.donations"
    assert_includes menu_keys, "decidim.bih.menu.impact"
    assert_includes menu_keys, "decidim.bih.menu.mi_bot"
    assert_includes menu_keys, "decidim.bih.menu.community_hub"
    assert_includes menu_keys, "decidim.bih.menu.volunteer"
    assert_includes menu_keys, "decidim.bih.menu.komsiluk_board"
    assert_includes menu_keys, "decidim.bih.menu.wallet"
    assert_includes menu_keys, "decidim.bih.menu.komsiluk"
  end

  def test_required_brand_asset_reviews_cover_local_branding_families
    reviews = Decidim::Bih.required_brand_asset_reviews
    ids = reviews.map { |review| review.fetch(:id) }

    assert_equal ids.uniq, ids
    assert_includes ids, "theme_and_fonts"
    assert_includes ids, "mi_mark"
    assert_includes ids, "stickers"
    assert_includes ids, "chat_and_install_helpers"
    assert(reviews.all? { |review| review.fetch(:public_paths).all? { |path| path.start_with?("/") } })
    assert(
      reviews.all? do |review|
        note = review.fetch(:review_note).to_s
        note.include?("Review") || note.include?("Replace") || note.include?("Keep")
      end
    )
  end

  private

  def valid_lifecycle?(lifecycle)
    lifecycle.to_s.include?("_") || lifecycle == "canonical"
  end
end
