# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class PublicPathsTest < Minitest::Test
  def setup
    @original_mount_path = Decidim::Bih.public_mount_path
    @original_magic_link_short_path_enabled = Decidim::Bih.magic_link_short_path_enabled
    @original_registration_base_path = Decidim::Bih.registration_base_path
  end

  def teardown
    Decidim::Bih.public_mount_path = @original_mount_path
    Decidim::Bih.magic_link_short_path_enabled = @original_magic_link_short_path_enabled
    Decidim::Bih.registration_base_path = @original_registration_base_path
  end

  def test_public_path_uses_default_biceriseno_mount
    assert_equal "/biceriseno", Decidim::Bih.public_path
    assert_equal "/biceriseno/mapa", Decidim::Bih.public_path("mapa")
    assert_equal "/biceriseno/mapa", Decidim::Bih.public_path("/mapa")
  end

  def test_public_path_uses_configured_mount
    Decidim::Bih.public_mount_path = "/grad"

    assert_equal "/grad", Decidim::Bih.public_path
    assert_equal "/grad/zajednistvo?tab=tabla", Decidim::Bih.public_path("zajednistvo?tab=tabla")
  end

  def test_public_path_supports_root_mount
    Decidim::Bih.public_mount_path = "/"

    assert_equal "/", Decidim::Bih.public_path
    assert_equal "/prijave/BR-2026-0001", Decidim::Bih.public_path("prijave/BR-2026-0001")
  end

  def test_public_url_combines_base_url_and_public_path
    Decidim::Bih.public_mount_path = "/grad"

    assert_equal(
      "https://example.test/grad/donacije",
      Decidim::Bih.public_url("donacije", base_url: "https://example.test/")
    )
  end

  def test_magic_link_path_defaults_to_short_host_route
    Decidim::Bih.public_mount_path = "/grad"

    assert_equal "/v/raw-token", Decidim::Bih.magic_link_path("raw-token")
  end

  def test_magic_link_path_can_use_mounted_engine_route
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.magic_link_short_path_enabled = false

    assert_equal "/grad/v/raw-token", Decidim::Bih.magic_link_path("raw-token")
    assert_equal "/v/raw-token", Decidim::Bih.magic_link_path("raw-token", short: true)
  end

  def test_magic_link_url_combines_host_and_configured_path
    Decidim::Bih.public_mount_path = "/moja-platforma"
    Decidim::Bih.magic_link_short_path_enabled = false

    assert_equal(
      "https://example.test/moja-platforma/v/raw-token",
      Decidim::Bih.magic_link_url("raw-token", host: "example.test")
    )
    assert_equal(
      "http://example.test/v/raw-token",
      Decidim::Bih.magic_link_url("raw-token", host: "http://example.test/", short: true)
    )
  end

  def test_magic_link_helpers_require_token_and_host
    assert_raises(ArgumentError) { Decidim::Bih.magic_link_path("") }
    assert_raises(ArgumentError) { Decidim::Bih.magic_link_url("raw-token", host: " ") }
  end

  # A host that leaves registration_base_path unset is served the one-step
  # registration from under the engine mount.
  def test_registration_path_for_falls_back_to_the_engine_mount
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = nil

    assert_equal "/grad/registracija", Decidim::Bih.registration_path_for
    assert_equal "/grad/registracija/potvrda", Decidim::Bih.registration_path_for("potvrda")
    assert_equal "/grad/registracija/potvrda", Decidim::Bih.registration_path_for("/potvrda")
    assert_equal "/grad/registracija/potvrda?x=1", Decidim::Bih.registration_path_for("potvrda?x=1")
  end

  # A host that serves it at a root path owns the URL, and every step of the
  # flow stays under that base — never under the mount.
  def test_registration_path_for_follows_the_configured_base_path
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = "/registracija"

    assert_equal "/registracija", Decidim::Bih.registration_path_for
    assert_equal "/registracija/potvrda", Decidim::Bih.registration_path_for("potvrda")
    assert_equal "/registracija/potvrda?x=1", Decidim::Bih.registration_path_for("potvrda?x=1")

    # A base typed without the leading slash, or with a trailing one, is the
    # same base: a host initializer must not have to be exact about either.
    Decidim::Bih.registration_base_path = "registracija/"

    assert_equal "/registracija", Decidim::Bih.registration_path_for
    assert_equal "/registracija/potvrda", Decidim::Bih.registration_path_for("potvrda")
  end

  # A base of "/" means the registration IS the site root. Chomping the
  # trailing slash off it leaves nothing, and nothing is not a path: the
  # helper would hand the pending page an empty href and the resume e-mail a
  # bare origin. #public_path already guards its own degenerate mount the same
  # way, and these two rules must not disagree.
  def test_registration_path_for_guards_a_root_base_path
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = "/"

    assert_equal "/", Decidim::Bih.registration_path_for
    assert_equal "/potvrda", Decidim::Bih.registration_path_for("potvrda")
    assert_equal "/potvrda", Decidim::Bih.registration_path_for("/potvrda")
    assert_equal "/potvrda?x=1", Decidim::Bih.registration_path_for("potvrda?x=1")
    assert_equal "/?x=1", Decidim::Bih.registration_path_for("?x=1")
    assert_equal "https://example.test/", Decidim::Bih.registration_url(host: "example.test")

    # "//" is the same degenerate root typed twice. #public_path's own
    # normalization collapses a run of trailing slashes, so this must too —
    # a single chomp leaves "/" behind and builds "//potvrda", which is a
    # protocol-relative URL, not a path on this host.
    Decidim::Bih.registration_base_path = "//"

    assert_equal "/", Decidim::Bih.registration_path_for
    assert_equal "/potvrda", Decidim::Bih.registration_path_for("potvrda")
  end

  def test_registration_url_combines_host_and_registration_path
    Decidim::Bih.public_mount_path = "/grad"
    Decidim::Bih.registration_base_path = nil

    assert_equal(
      "https://example.test/grad/registracija/potvrda?pending_token=abc",
      Decidim::Bih.registration_url("potvrda?pending_token=abc", host: "example.test")
    )

    Decidim::Bih.registration_base_path = "/registracija"

    assert_equal(
      "https://example.test/registracija/potvrda?pending_token=abc",
      Decidim::Bih.registration_url("potvrda?pending_token=abc", host: "example.test")
    )
    assert_equal(
      "http://example.test/registracija",
      Decidim::Bih.registration_url(host: "http://example.test/")
    )
  end

  def test_registration_url_requires_a_host
    assert_raises(ArgumentError) { Decidim::Bih.registration_url("potvrda", host: " ") }
  end

  # The invite surfaces — header pill, top nudge, leaderboard CTA, "Još" sheet,
  # the account checklist and the referral bell — must all point at ONE place.
  # That place follows the mount, so a host that remounts the engine moves every
  # invite entry point with it and none of them can drift apart.
  def test_invite_path_follows_the_public_mount
    assert_equal "/biceriseno/zajednistvo?tab=pozovi", Decidim::Bih.invite_path

    Decidim::Bih.public_mount_path = "/grad"

    assert_equal "/grad/zajednistvo?tab=pozovi", Decidim::Bih.invite_path
  end

  def test_invite_path_supports_root_mount
    Decidim::Bih.public_mount_path = "/"

    assert_equal "/zajednistvo?tab=pozovi", Decidim::Bih.invite_path
  end
end
