# frozen_string_literal: true

require "test_helper"
require "decidim/bih"
require_relative "../../../../../app/services/decidim/bih/goodwill/invite_links"

class InviteLinksTest < Minitest::Test
  Referrer = Struct.new(:nickname)

  def setup
    @original_mount_path = Decidim::Bih.public_mount_path
    @original_base = Decidim::Bih.registration_base_path
    @original_short = Decidim::Bih.invite_short_path
    Decidim::Bih.invite_short_path = nil
  end

  def teardown
    Decidim::Bih.public_mount_path = @original_mount_path
    Decidim::Bih.registration_base_path = @original_base
    Decidim::Bih.invite_short_path = @original_short
  end

  def test_landing_url_is_the_short_link_when_the_host_configures_one
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = "/registracija"
    Decidim::Bih.invite_short_path = "/p"

    links = Decidim::Bih::Goodwill::InviteLinks.new(
      Referrer.new("ana-2"),
      base_url: "https://example.test"
    )

    assert_equal "https://example.test/p/ana-2", links.landing_url
    assert_includes CGI.unescape(links.whatsapp_url), "https://example.test/p/ana-2"
  end

  def test_short_link_escapes_the_code_and_tolerates_slashes_in_the_setting
    Decidim::Bih.invite_short_path = "p/"

    links = Decidim::Bih::Goodwill::InviteLinks.new(
      Referrer.new("ana test"),
      base_url: "https://example.test/"
    )

    assert_equal "https://example.test/p/ana%20test", links.landing_url
  end

  def test_qr_svg_encodes_the_landing_url_and_is_never_nil_for_a_valid_code
    Decidim::Bih.invite_short_path = "/p"

    links = Decidim::Bih::Goodwill::InviteLinks.new(
      Referrer.new("ana"),
      base_url: "https://example.test"
    )

    svg = links.qr_svg
    assert_match(/\A<svg/, svg)
    assert_includes svg, "viewBox"
    assert_equal links.qr_svg, svg, "the QR is memoised, not re-rendered per call"
  end

  def test_landing_url_uses_configured_public_mount_path
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = nil

    links = Decidim::Bih::Goodwill::InviteLinks.new(
      Referrer.new("ana test"),
      base_url: "https://example.test"
    )

    assert_equal "https://example.test/grad/registracija?ref=ana+test", links.landing_url
  end

  def test_landing_url_follows_the_host_registration_base_path
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = "/registracija"

    links = Decidim::Bih::Goodwill::InviteLinks.new(
      Referrer.new("ana"),
      base_url: "https://example.test"
    )

    assert_equal "https://example.test/registracija?ref=ana", links.landing_url
  end

  def test_share_urls_include_landing_url
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = nil

    links = Decidim::Bih::Goodwill::InviteLinks.new(
      Referrer.new("ana"),
      base_url: "https://example.test",
      message: "Pridruzi se"
    )

    assert_includes CGI.unescape(links.whatsapp_url), "https://example.test/grad/registracija?ref=ana"
    assert_includes CGI.unescape(links.facebook_url), "https://example.test/grad/registracija?ref=ana"
    assert_includes CGI.unescape(links.viber_url), "https://example.test/grad/registracija?ref=ana"
  end
end
