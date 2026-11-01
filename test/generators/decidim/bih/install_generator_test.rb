# frozen_string_literal: true

require "test_helper"
require "digest"
require "ostruct"
require "rack/attack"
require "rails/generators"
require "rails/generators/test_case"
require "generators/decidim/bih/install_generator"
require_relative "../../../../app/services/decidim/bih/throttling"

class DecidimBihInstallGeneratorTest < Rails::Generators::TestCase
  tests Decidim::Bih::Generators::InstallGenerator
  destination File.expand_path("../../../../tmp/generators/install", __dir__)
  setup :prepare_destination

  def test_generates_host_contract_files
    run_generator ["--mount-path=/moja-platforma", "--no-short-magic-links"]

    assert_file "config/initializers/decidim_bih.rb", /DECIDIM_BIH_PUBLIC_MOUNT_PATH/
    assert_file "config/initializers/decidim_bih.rb", %r{"/moja-platforma"}
    assert_file "config/initializers/decidim_bih.rb", /"false"/
    assert_file "config/initializers/decidim_bih.rb", /Decidim::Bih.flagship_process_slug/
    assert_file "config/initializers/decidim_bih.rb", /Decidim::Bih.campaign_hashtag/
    assert_file "config/initializers/decidim_bih.rb", /Decidim::Bih.geocoder_base_url/
    assert_file "config/initializers/decidim_bih.rb", /Decidim::Bih.geocoder_search_path/
    # Phone-first registration is scaffolded commented out, and never without
    # its cutoff: with the flag on and no cutoff nothing is grandfathered, and
    # every legacy account loses e-mail password reset until it confirms
    # again. A host that meets the flag for the first time in its own
    # initializer meets that warning with it.
    assert_file "config/initializers/decidim_bih.rb", /# Decidim::Bih\.phone_first_registration = true/
    assert_file "config/initializers/decidim_bih.rb", /# Decidim::Bih\.phone_first_registration_since =/
    assert_file "config/initializers/decidim_bih.rb", /grandfathered/

    Decidim::Bih.required_public_assets.each do |asset|
      assert_file "public/#{asset.delete_prefix("/")}"
    end

    assert_file "config/initializers/decidim_bih_rack_attack.rb", %r{Rack::Attack.throttle\("bih/magic-link"}
    assert_file "config/initializers/decidim_bih_rack_attack.rb", %r{Rack::Attack.throttle\("bih/community-contributions\.write/ip"}
    assert_file "config/initializers/decidim_bih_rack_attack.rb", %r{Rack::Attack.throttle\("bih/infobip-chat\.webhook/ip"}
    assert_file "config/initializers/decidim_bih_rack_attack.rb", /Decidim::Bih.magic_link_short_path_enabled/

    assert_file "docs/decidim_bih_host_contract.md", %r{mount Decidim::Bih::Engine => "/moja-platforma"}
    assert_file "docs/decidim_bih_host_contract.md", %r{/leaflet/leaflet.css}
    assert_file "docs/decidim_bih_host_contract.md", /magic_links.consume/
    assert_file "docs/decidim_bih_host_contract.md", %r{/moja-platforma/viber/webhook}
    assert_file "docs/decidim_bih_host_contract.md", %r{/moja-platforma/whatsapp/webhook}
    assert_file "docs/decidim_bih_host_contract.md", %r{/moja-platforma/messenger/webhook}
    assert_file "docs/decidim_bih_host_contract.md", %r{/moja-platforma/instagram/webhook}
    assert_file "docs/decidim_bih_host_contract.md", %r{magic_links\.consume.*POST /moja-platforma/v/:token; limit}m
    assert_file "docs/decidim_bih_host_contract.md", /Public Write Route Classification/
    assert_file "docs/decidim_bih_host_contract.md", %r{komsiluk\.suggest.*POST /moja-platforma/komsiluk/suggest}m
    assert_file "docs/decidim_bih_host_contract.md", /community_projects\.create.*throttles community_contributions\.write_by_ip, community_contributions\.write_by_session/m
    assert_file "docs/decidim_bih_host_contract.md", %r{contribution_offers\.confirm.*POST /moja-platforma/volontiranje/ponude/:id/potvrdi}m
    assert_file "docs/decidim_bih_host_contract.md", /organizations\.create.*no throttle:/m
    assert_file "docs/decidim_bih_host_contract.md", /host_contract:install_assets/
    assert_file "docs/decidim_bih_host_contract.md", /compatibility namespace/
    assert_file "docs/decidim_bih_host_contract.md", /local branding/
    assert_file "docs/decidim_bih_host_contract.md", /Public Surface Review/
    assert_file "docs/decidim_bih_host_contract.md", %r{reports\.new.*GET /moja-platforma/prijave/new}m
    assert_file "docs/decidim_bih_host_contract.md", /community_hub\.show.*decidim\.bih\.menu\.community_hub/m
    assert_file "docs/decidim_bih_host_contract.md", %r{mz_directory\.index.*GET /moja-platforma/mjesne-zajednice}m
    assert_file "docs/decidim_bih_host_contract.md", /Brand Asset Review/
    assert_file "docs/decidim_bih_host_contract.md", /BRAND_ASSET_REPLACEMENT/
    assert_file "docs/decidim_bih_host_contract.md", /theme_and_fonts/
    assert_file "docs/decidim_bih_host_contract.md", /mi_mark/
    assert_file "docs/decidim_bih_host_contract.md", /Hard Decidim Module Dependencies/
    assert_file "docs/decidim_bih_host_contract.md", /decidim-budgets/
    assert_file "docs/decidim_bih_host_contract.md", /decidim-verifications/
    assert_file "docs/decidim_bih_host_contract.md", /Privacy And Audit Event Contract/
    assert_file "docs/decidim_bih_host_contract.md", /report_photo_drafts.*ReportPhotoDraft.*\(2 hours\)/
    assert_file "docs/decidim_bih_host_contract.md", /pending_registrations.*PendingLifecycle.*\(7 days\)/
    assert_file "docs/decidim_bih_host_contract.md", /decidim_bih:host_contract:privacy_audit/
    assert_file "docs/decidim_bih_host_contract.md", /report_contacts.*REPORT_CONTACT_BEFORE/m
    assert_file "docs/decidim_bih_host_contract.md", /chat_feedback.*CHAT_FEEDBACK_BEFORE/m
    assert_file "docs/decidim_bih_host_contract.md", /report_events.*table:decidim_bih_report_events/m
    assert_file "docs/decidim_bih_host_contract.md", /admin_analytics_exports.*derived_csv/m
  end

  def test_default_short_magic_link_contract_is_generated
    run_generator ["--mount-path=/moja-platforma", "--skip-assets"]

    assert_file "config/initializers/decidim_bih.rb", /"true"/
    assert_file "docs/decidim_bih_host_contract.md", %r{get "/v/:token"}
    assert_file "docs/decidim_bih_host_contract.md", %r{post "/v/:token"}
    assert_file "docs/decidim_bih_host_contract.md", %r{magic_links\.consume.*POST /v/:token, /moja-platforma/v/:token; limit}m
  end

  def test_generated_rack_attack_initializer_matches_custom_mount_contract
    run_generator ["--mount-path=/moja-platforma", "--no-short-magic-links", "--skip-assets", "--skip-docs"]

    with_generated_rack_attack_initializer do
      assert_throttle_discriminator "bih/reports.create/ip",
                                    path: "/moja-platforma/prijave",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/reports.corroborate/ip",
                                    path: "/moja-platforma/prijave/BR-2026-0001/potvrdi",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/chat.create/ip",
                                    path: "/moja-platforma/chat",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/chat.feedback/ip",
                                    path: "/moja-platforma/chat/feedback",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/community-contributions.write/ip",
                                    path: "/moja-platforma/volontiranje/potrebe/17/ponude",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/community-contributions.write/ip",
                                    path: "/moja-platforma/projekti/prijave/17",
                                    method: "PATCH",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/community-contributions.write/session",
                                    path: "/moja-platforma/volontiranje/ponude/17/isporuceno",
                                    method: "POST",
                                    session: fake_session("contribution-session-id"),
                                    expected: session_key("contribution-session-id")
      assert_throttle_discriminator "bih/community-contributions.write/ip",
                                    path: "/moja-platforma/projekti/prijave/17",
                                    method: "POST",
                                    expected: nil
      assert_throttle_discriminator "bih/community-contributions.write/ip",
                                    path: "/moja-platforma/volontiranje/potrebe",
                                    method: "GET",
                                    expected: nil
      assert_throttle_discriminator "bih/viber.webhook/ip",
                                    path: "/moja-platforma/viber/webhook",
                                    method: "POST",
                                    expected: "203.0.113.10"
      %w(whatsapp messenger instagram).each do |channel|
        assert_throttle_discriminator "bih/infobip-chat.webhook/ip",
                                      path: "/moja-platforma/#{channel}/webhook",
                                      method: "POST",
                                      expected: "203.0.113.10"
      end
      assert_throttle_discriminator "bih/infobip-chat.webhook/ip",
                                    path: "/moja-platforma/whatsapp/webhook",
                                    method: "GET",
                                    expected: nil
      assert_throttle_discriminator "bih/komsiluk.suggest/ip",
                                    path: "/moja-platforma/komsiluk/suggest",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/komsiluk.suggest/session",
                                    path: "/moja-platforma/komsiluk/suggest",
                                    method: "POST",
                                    session: fake_session("komsiluk-suggest-session-id"),
                                    expected: session_key("komsiluk-suggest-session-id")
      assert_throttle_discriminator "bih/komsiluk-board.write/ip",
                                    path: "/moja-platforma/komsiluk-board/123/prijavi",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/komsiluk-board.write/session",
                                    path: "/moja-platforma/komsiluk-board/123/zatvori",
                                    method: "PATCH",
                                    session: fake_session("komsiluk-board-session-id"),
                                    expected: session_key("komsiluk-board-session-id")
      assert_throttle_discriminator "bih/magic-link",
                                    path: "/moja-platforma/v/token-123",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/magic-link",
                                    path: "/v/token-123",
                                    method: "POST",
                                    expected: nil
      assert_throttle_discriminator "bih/phone-login/ip",
                                    path: "/moja-platforma/prijava",
                                    method: "POST",
                                    params: { "phone" => "+387 65 123 456" },
                                    expected: "203.0.113.10"
      # Never the number itself, and never a bare digest of it either: the
      # whole BiH mobile space is a lookup table away. One shared, salted
      # helper — the host's own rules call the same one.
      assert_throttle_discriminator "bih/phone-login/phone",
                                    path: "/moja-platforma/prijava",
                                    method: "POST",
                                    params: { "phone" => "+387 65 123 456" },
                                    expected: Decidim::Bih::Throttling.phone_key("+38765123456")
      refute_includes Decidim::Bih::Throttling.phone_key("+38765123456").to_s, "38765123456"
      assert_throttle_discriminator "bih/phone-login-code/ip",
                                    path: "/moja-platforma/prijava/kod",
                                    method: "POST",
                                    expected: "203.0.113.10"

      # The launch venue puts hundreds of citizens behind one NAT, so every
      # authenticated phone surface counts per session instead — and the raw
      # session id never becomes the key either.
      verification_session = fake_session("verification-session-id")
      verification_key = session_key("verification-session-id")
      assert_throttle_discriminator "bih/phone-verification-code/session",
                                    path: "/moja-platforma/verifikacija/telefon/kod",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      assert_throttle_discriminator "bih/phone-verification-resend/session",
                                    path: "/moja-platforma/verifikacija/telefon/ponovo",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      assert_throttle_discriminator "bih/phone-verification-change/session",
                                    path: "/moja-platforma/verifikacija/telefon",
                                    method: "DELETE",
                                    session: verification_session,
                                    expected: verification_key
      # .json and the extension-less form share one budget rather than
      # doubling it.
      assert_throttle_discriminator "bih/phone-verification-status/session",
                                    path: "/moja-platforma/verifikacija/telefon/status.json",
                                    method: "GET",
                                    session: verification_session,
                                    expected: verification_key

      # The one-step registration's pending page does the same four things for
      # the same citizen, so it spends the SAME per-session budgets — one set
      # of paid messages and one set of guesses, however many pages offer them.
      # Its poll is a POST, because that variant can sign the browser in.
      assert_throttle_discriminator "bih/phone-verification-code/session",
                                    path: "/moja-platforma/registracija/potvrda/kod",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      assert_throttle_discriminator "bih/phone-verification-resend/session",
                                    path: "/moja-platforma/registracija/potvrda/ponovo",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      assert_throttle_discriminator "bih/phone-verification-change/session",
                                    path: "/moja-platforma/registracija/potvrda",
                                    method: "DELETE",
                                    session: verification_session,
                                    expected: verification_key
      # "Start over" is the heavier version of the same "this number is wrong"
      # move, so it spends the change budget instead of a fresh one.
      assert_throttle_discriminator "bih/phone-verification-change/session",
                                    path: "/moja-platforma/registracija/potvrda/pocni-ispocetka",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      assert_throttle_discriminator "bih/phone-verification-status/session",
                                    path: "/moja-platforma/registracija/potvrda/status",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      # Exact paths, so nothing a later route hangs below ".../status" quietly
      # joins the poll's budget.
      assert_throttle_discriminator "bih/phone-verification-status/session",
                                    path: "/moja-platforma/registracija/potvrda/status/extra",
                                    method: "POST",
                                    session: verification_session,
                                    expected: nil

      # /users and /sms/authorizations are Decidim core routes: they must not
      # move with the engine's mount.
      assert_throttle_discriminator "bih/registration-create/ip",
                                    path: "/users",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/registration-create/ip",
                                    path: "/moja-platforma/users",
                                    method: "POST",
                                    expected: nil
      # The one-step form is the other door into the same room. With no
      # registration_base_path configured it lives under the mount; a host that
      # serves it at a root path moves this rule with it.
      assert_throttle_discriminator "bih/registration-create/ip",
                                    path: "/moja-platforma/registracija",
                                    method: "POST",
                                    expected: "203.0.113.10"
      assert_throttle_discriminator "bih/sms-authorization-create/session",
                                    path: "/sms/authorizations",
                                    method: "POST",
                                    session: verification_session,
                                    expected: verification_key
      # Decidim's form object merges the NESTED mobile_phone params over the
      # flat ones, so the nested number is the one that gets the paid message
      # — and therefore the one that must be counted. Reading the flat key
      # first would let a decoy spend someone else's budget.
      assert_throttle_discriminator "bih/sms-authorization-create/phone",
                                    path: "/sms/authorizations",
                                    method: "POST",
                                    params: {
                                      "mobile_phone" => { "mobile_phone_number" => "+387 65 123 456" },
                                      "mobile_phone_number" => "+38765999999"
                                    },
                                    expected: Decidim::Bih::Throttling.phone_key("+38765123456")
      assert_throttle_discriminator "bih/sms-authorization-create/phone",
                                    path: "/sms/authorizations",
                                    method: "POST",
                                    params: { "mobile_phone_number" => "+387 65 123 456" },
                                    expected: Decidim::Bih::Throttling.phone_key("+38765123456")
      # A crafted scalar where the form object should be must not raise inside
      # the middleware — that would hand an attacker a 500 on the endpoint
      # this rule exists to protect.
      assert_throttle_discriminator "bih/sms-authorization-create/phone",
                                    path: "/sms/authorizations",
                                    method: "POST",
                                    params: { "mobile_phone" => "x" },
                                    expected: nil
    end
  end

  # A host that serves the one-step registration at its own root path still
  # answers under the engine mount, and both are the same controller spending
  # the same paid messages. Rules that followed only the configured base would
  # leave the mounted path open.
  def test_a_configured_registration_base_is_metered_alongside_the_mounted_one
    run_generator ["--mount-path=/moja-platforma", "--no-short-magic-links"]

    original_base = Decidim::Bih.registration_base_path
    Decidim::Bih.registration_base_path = "/registracija"
    begin
      with_generated_rack_attack_initializer do
        session = fake_session("configured-base-session")
        key = session_key("configured-base-session")

        ["/registracija/potvrda/kod", "/moja-platforma/registracija/potvrda/kod"].each do |path|
          assert_throttle_discriminator "bih/phone-verification-code/session",
                                        path:, method: "POST", session:, expected: key
        end
        ["/registracija/potvrda/ponovo", "/moja-platforma/registracija/potvrda/ponovo"].each do |path|
          assert_throttle_discriminator "bih/phone-verification-resend/session",
                                        path:, method: "POST", session:, expected: key
        end
        ["/registracija/potvrda", "/moja-platforma/registracija/potvrda"].each do |path|
          assert_throttle_discriminator "bih/phone-verification-change/session",
                                        path:, method: "DELETE", session:, expected: key
        end
        ["/registracija/potvrda/status", "/moja-platforma/registracija/potvrda/status.json"].each do |path|
          assert_throttle_discriminator "bih/phone-verification-status/session",
                                        path:, method: "POST", session:, expected: key
        end
        ["/registracija", "/moja-platforma/registracija", "/users"].each do |path|
          assert_throttle_discriminator "bih/registration-create/ip", path:, method: "POST", expected: "203.0.113.10"
        end
      end
    ensure
      Decidim::Bih.registration_base_path = original_base
    end
  end

  # The bug this scheme nearly shipped with: keying on the session COOKIE.
  # Under CookieStore that value is AES-GCM ciphertext rewritten on nearly
  # every authenticated request, so two requests from one signed-in citizen
  # would land in two counters and no per-session throttle could ever fire.
  def test_a_rotating_session_cookie_still_counts_under_one_session_key
    run_generator ["--mount-path=/moja-platforma", "--no-short-magic-links"]

    with_generated_rack_attack_initializer do
      first = throttle_discriminator(
        "bih/phone-verification-code/session",
        path: "/moja-platforma/verifikacija/telefon/kod", method: "POST",
        session: fake_session("one-citizen"), cookie: "_test_session=ciphertext-one"
      )
      second = throttle_discriminator(
        "bih/phone-verification-code/session",
        path: "/moja-platforma/verifikacija/telefon/kod", method: "POST",
        session: fake_session("one-citizen"), cookie: "_test_session=totally-different-ciphertext"
      )

      assert_equal first, second, "a rotating cookie must not hand the same citizen a fresh budget"
      assert_equal session_key("one-citizen"), first
      refute_includes first, "one-citizen", "the raw session id must not reach the throttle store"
    end
  end

  # No session at all (an unauthenticated request that still hits the path):
  # the rule must count something rather than nothing.
  def test_a_request_with_no_session_falls_back_to_the_ip
    run_generator ["--mount-path=/moja-platforma", "--no-short-magic-links"]

    with_generated_rack_attack_initializer do
      assert_throttle_discriminator "bih/phone-verification-status/session",
                                    path: "/moja-platforma/verifikacija/telefon/status",
                                    method: "GET",
                                    expected: "ip:203.0.113.10"
    end
  end

  # The generated rules are the host contract, so the numbers in them are not
  # free either: the registry is the single source for every limit and period.
  def test_generated_rack_attack_limits_and_periods_match_the_registry
    run_generator ["--mount-path=/moja-platforma", "--no-short-magic-links"]

    with_generated_rack_attack_initializer do
      Decidim::Bih.required_public_throttles.each do |contract|
        throttle = Rack::Attack.throttles.fetch(contract.fetch(:name))

        assert_equal contract.fetch(:limit), throttle.limit, "#{contract.fetch(:name)} limit"
        assert_equal contract.fetch(:period), throttle.period, "#{contract.fetch(:name)} period"
      end
    end
  end

  def test_can_skip_rack_attack_and_docs
    run_generator ["--skip-rack-attack", "--skip-docs", "--skip-assets"]

    assert_file "config/initializers/decidim_bih.rb"
    assert_no_file "public/mi/mi-theme.css"
    assert_no_file "config/initializers/decidim_bih_rack_attack.rb"
    assert_no_file "docs/decidim_bih_host_contract.md"
  end

  private

  def with_generated_rack_attack_initializer
    original_mount_path = Decidim::Bih.public_mount_path
    original_short_magic_links = Decidim::Bih.magic_link_short_path_enabled
    original_throttles = Rack::Attack.throttles.dup

    Decidim::Bih.public_mount_path = "/moja-platforma"
    Decidim::Bih.magic_link_short_path_enabled = false
    Rack::Attack.throttles.clear

    with_fake_rails_session_key do
      load File.join(destination_root, "config/initializers/decidim_bih_rack_attack.rb")
      yield
    end
  ensure
    Rack::Attack.throttles.clear
    Rack::Attack.throttles.merge!(original_throttles) if original_throttles
    Decidim::Bih.public_mount_path = original_mount_path
    Decidim::Bih.magic_link_short_path_enabled = original_short_magic_links
  end

  def with_fake_rails_session_key
    singleton = class << Rails; self; end
    had_application = Rails.respond_to?(:application)
    original_application = Rails.method(:application) if had_application
    fake_application = OpenStruct.new(
      config: OpenStruct.new(
        session_options: { key: "_test_session" }
      )
    )

    Rails.define_singleton_method(:application) { fake_application }
    yield
  ensure
    singleton.send(:remove_method, :application)
    Rails.define_singleton_method(:application, original_application) if had_application
  end

  def assert_throttle_discriminator(name, path:, method:, expected:, params: {}, cookie: nil, session: nil) # rubocop:disable Metrics/ParameterLists
    actual = throttle_discriminator(name, path:, method:, params:, cookie:, session:)
    message = "#{name} should match #{method} #{path}"
    return assert_nil actual, message if expected.nil?

    assert_equal expected, actual, message
  end

  def throttle_discriminator(name, path:, method:, params: {}, cookie: nil, session: nil) # rubocop:disable Metrics/ParameterLists
    Rack::Attack.throttles.fetch(name).block.call(rack_request(path:, method:, params:, cookie:, session:))
  end

  # Stands in for ActionDispatch::Request::Session: the only thing the
  # generated rules ask a session for is its id. A bare Hash (what a request
  # with no session middleware carries) deliberately has none.
  def fake_session(id) = OpenStruct.new(id:)

  def session_key(id) = "s:#{Digest::SHA256.hexdigest(id)[0, 32]}"

  def rack_request(path:, method:, params:, cookie:, session: nil)
    env = Rack::MockRequest.env_for(
      path,
      :method => method,
      :params => params,
      "REMOTE_ADDR" => "203.0.113.10",
      "HTTP_COOKIE" => cookie
    )
    env["rack.session"] = session || {}

    Rack::Request.new(env)
  end
end
