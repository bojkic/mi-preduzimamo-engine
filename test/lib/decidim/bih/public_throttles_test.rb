# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class PublicThrottlesTest < Minitest::Test
  def test_required_public_throttles_are_named_and_unique
    throttles = Decidim::Bih.required_public_throttles
    ids = throttles.map { |throttle| throttle.fetch(:id) }
    names = throttles.map { |throttle| throttle.fetch(:name) }

    assert_equal ids.uniq, ids
    assert_equal names.sort, names
    assert_equal names.uniq, names
    assert_valid_throttle_limits throttles
    assert_valid_throttle_methods throttles
    assert_valid_throttle_discriminators throttles
    assert_valid_throttle_paths throttles
  end

  def test_required_public_throttles_cover_write_families
    throttles = Decidim::Bih.required_public_throttles
    names = throttles.map { |throttle| throttle.fetch(:name) }
    ids = throttles.map { |throttle| throttle.fetch(:id) }

    assert_includes names, "bih/reports.create/ip"
    assert_includes names, "bih/reports.corroborate/ip"
    assert_includes names, "bih/chat.create/ip"
    assert_includes names, "bih/chat.feedback/ip"
    assert_includes names, "bih/community-contributions.write/ip"
    assert_includes names, "bih/community-contributions.write/session"
    assert_includes names, "bih/infobip-chat.webhook/ip"
    assert_includes names, "bih/viber.webhook/ip"
    assert_includes names, "bih/komsiluk.suggest/ip"
    assert_includes names, "bih/komsiluk.suggest/session"
    assert_includes names, "bih/komsiluk-board.write/ip"
    assert_includes names, "bih/komsiluk-board.write/session"
    assert_includes names, "bih/magic-link"
    assert_includes names, "bih/phone-login/ip"
    assert_includes names, "bih/phone-login-code/ip"
    assert_includes names, "bih/phone-login/phone"
    assert_includes names, "bih/phone-verification-code/session"
    assert_includes names, "bih/phone-verification-resend/session"
    assert_includes names, "bih/phone-verification-change/session"
    assert_includes names, "bih/phone-verification-status/session"
    assert_includes names, "bih/registration-create/ip"
    assert_includes names, "bih/sms-authorization-create/session"
    assert_includes names, "bih/sms-authorization-create/phone"

    assert_includes ids, "reports.create"
    assert_includes ids, "reports.corroborate"
    assert_includes ids, "chat.feedback"
    assert_includes ids, "community_contributions.write_by_ip"
    assert_includes ids, "community_contributions.write_by_session"
    assert_includes ids, "infobip-chat.webhook"
    assert_includes ids, "komsiluk.suggest_by_session"
    assert_includes ids, "komsiluk_board.write_by_session"
    assert_includes ids, "viber.webhook"
    assert_includes ids, "phone_verification.status_by_session"
    assert_includes ids, "registration.create"
    assert_includes ids, "sms_authorization.create_by_session"
    assert_includes ids, "sms_authorization.create_by_phone"
  end

  # /users and /sms/authorizations are Decidim core routes, not engine-mounted
  # ones: a host that moves the engine's mount must not see these move with it.
  def test_host_owned_registration_contracts_do_not_move_with_the_engine_mount
    throttles = Decidim::Bih.required_public_throttles_for_mount(mount_path: "/moja-platforma")
    registration = throttles.find { |throttle| throttle.fetch(:id) == "registration.create" }
    sms_by_phone = throttles.find { |throttle| throttle.fetch(:id) == "sms_authorization.create_by_phone" }
    status = throttles.find { |throttle| throttle.fetch(:id) == "phone_verification.status_by_session" }

    # /users never moves; the one-step form is served either at the host's own
    # root path or under the mount, and both doors share the ceiling.
    assert_equal ["/users", "/registracija", "/moja-platforma/registracija"], registration.fetch(:paths)
    assert registration.fetch(:host_route)
    assert_equal ["/sms/authorizations"], sms_by_phone.fetch(:paths)
    assert_equal "phone", sms_by_phone.fetch(:discriminator)
    assert_equal 3, sms_by_phone.fetch(:limit)
    assert_equal [
      "/moja-platforma/verifikacija/telefon/status",
      "/registracija/potvrda/status",
      "/moja-platforma/registracija/potvrda/status"
    ], status.fetch(:paths)
    assert_equal %w(GET POST), status.fetch(:methods)
  end

  # R-D3: the registration pending page and the signed-in verification page do
  # the same four things for the same citizen, so they count against ONE
  # per-session budget each. A second budget would only mean a second set of
  # paid messages and a second set of guesses for whoever rotates sessions.
  def test_the_registration_pending_page_shares_the_verification_budgets
    throttles = Decidim::Bih.required_public_throttles_for_mount(mount_path: "/moja-platforma")
    by_id = throttles.index_by { |throttle| throttle.fetch(:id) }

    {
      "phone_verification.code_by_session" => "kod",
      "phone_verification.resend_by_session" => "ponovo",
      "phone_verification.status_by_session" => "status"
    }.each do |id, suffix|
      paths = by_id.fetch(id).fetch(:paths)

      assert_includes paths, "/registracija/potvrda/#{suffix}", id
      assert_includes paths, "/moja-platforma/registracija/potvrda/#{suffix}", id
    end

    change = by_id.fetch("phone_verification.change_by_session")

    assert_includes change.fetch(:paths), "/registracija/potvrda"
    assert_includes change.fetch(:paths), "/moja-platforma/verifikacija/telefon"
    # Throwing the whole pending registration away spends the same budget as
    # changing the number on it.
    assert_includes change.fetch(:paths), "/registracija/potvrda/pocni-ispocetka"
    assert_includes change.fetch(:paths), "/moja-platforma/registracija/potvrda/pocni-ispocetka"
    assert_equal %w(DELETE POST), change.fetch(:methods)
  end

  # 17.9.2026: 310 citizens register and verify from one venue Wi-Fi NAT. Any
  # per-IP ceiling on a surface they all touch would lock the room out of the
  # step it came to do, so every authenticated phone-verification and
  # SMS-send contract is keyed per session; only the anonymous sign-up route
  # stays per IP, with a ceiling set for a whole venue rather than one home.
  def test_authenticated_phone_surfaces_are_keyed_per_session_not_per_shared_ip
    throttles = Decidim::Bih.required_public_throttles
    by_id = throttles.index_by { |throttle| throttle.fetch(:id) }

    %w(
      phone_verification.code_by_session
      phone_verification.resend_by_session
      phone_verification.change_by_session
      phone_verification.status_by_session
      sms_authorization.create_by_session
    ).each do |id|
      assert_equal "session", by_id.fetch(id).fetch(:discriminator), id
      assert_match(%r{/session\z}, by_id.fetch(id).fetch(:name), id)
    end

    registration = by_id.fetch("registration.create")
    assert_equal "ip", registration.fetch(:discriminator)
    assert_equal 200, registration.fetch(:limit),
                 "a whole venue registering over one NAT must fit under the anonymous per-IP ceiling"
    assert_equal 900, registration.fetch(:period)

    refute_includes throttles.map { |throttle| throttle.fetch(:name) }, "bih/sms-authorization-create/ip",
                    "the paid SMS form is metered per session and per number, never per shared IP"
  end

  # Every session-keyed rule computes its key only when the request matches
  # (so no rule reaches for a session on traffic it does not govern) and keys
  # on the session ID, never the session COOKIE — under CookieStore the cookie
  # value is ciphertext rewritten on nearly every authenticated request, which
  # would give each request its own counter. What the rules actually return is
  # asserted end to end against the rendered initializer in
  # DecidimBihInstallGeneratorTest.
  def test_generated_rack_attack_template_keys_every_session_rule_on_the_session_id
    template = generated_rack_attack_template
    extractor = template[/^public_session_id = lambda do \|request\|.*?^end$/m]

    refute_nil extractor
    assert_includes extractor, "request.session"
    refute_includes extractor, "request.cookies",
                    "the cookie value rotates under CookieStore; the session id is the stable key"
    assert_includes template, "Digest::SHA256.hexdigest(id)[0, 32]"
    assert_includes template, %(require "digest")

    session_contracts = Decidim::Bih.required_public_throttles.select do |throttle|
      throttle.fetch(:discriminator) == "session"
    end

    refute_empty session_contracts
    session_contracts.each do |throttle|
      rule = template[/^Rack::Attack\.throttle\("#{Regexp.escape(throttle.fetch(:name))}".*?^end$/m]

      refute_nil rule, throttle.fetch(:name)
      assert_includes rule, "public_session_discriminator.call(request) if",
                      "#{throttle.fetch(:name)} must compute the session key only when the request matches"
    end
  end

  def test_required_public_throttles_expand_for_custom_mount_path
    throttles = Decidim::Bih.required_public_throttles_for_mount(mount_path: "/moja-platforma")
    chat_feedback = throttles.find { |throttle| throttle.fetch(:id) == "chat.feedback" }
    report_create = throttles.find { |throttle| throttle.fetch(:id) == "reports.create" }
    report_corroborate = throttles.find { |throttle| throttle.fetch(:id) == "reports.corroborate" }
    magic_link = throttles.find { |throttle| throttle.fetch(:id) == "magic_links.consume" }
    phone_login_code = throttles.find { |throttle| throttle.fetch(:id) == "phone_login.code_by_ip" }
    contribution_writes = throttles.find { |throttle| throttle.fetch(:id) == "community_contributions.write_by_ip" }
    infobip_chat = throttles.find { |throttle| throttle.fetch(:id) == "infobip-chat.webhook" }

    assert_equal ["/moja-platforma/chat/feedback"], chat_feedback.fetch(:paths)
    assert_equal ["/moja-platforma/prijave"], report_create.fetch(:paths)
    assert_equal ["\\A/moja\\-platforma/prijave/[^/]+/potvrdi\\z"], report_corroborate.fetch(:path_regexes)
    assert_equal ["/v/:token", "/moja-platforma/v/:token"], magic_link.fetch(:paths)
    assert_equal ["/moja-platforma/prijava/kod"], phone_login_code.fetch(:paths)
    assert_includes contribution_writes.fetch(:paths), "/moja-platforma/projekti"
    assert_includes contribution_writes.fetch(:paths), "/moja-platforma/projekti/prijave/:id"
    assert_includes contribution_writes.fetch(:paths), "/moja-platforma/volontiranje/ponude/:id/potvrdi"
    assert_equal %w(
      /moja-platforma/whatsapp/webhook
      /moja-platforma/messenger/webhook
      /moja-platforma/instagram/webhook
    ), infobip_chat.fetch(:paths)
  end

  def test_generated_rack_attack_template_names_match_throttle_contract
    template = File.read(
      File.expand_path("../../../../lib/generators/decidim/bih/templates/decidim_bih_rack_attack.rb.erb", __dir__)
    )

    Decidim::Bih.required_public_throttles.each do |throttle|
      assert_includes template, "Rack::Attack.throttle(\"#{throttle.fetch(:name)}\""
    end
  end

  # A phone-keyed rule must never build its key itself: one shared, salted
  # helper keeps the host's rules and the generated ones counting the same
  # citizen under the same key, and keeps a bare (reversible) digest of a
  # number out of the throttle store.
  def test_generated_rack_attack_template_takes_every_phone_key_from_the_shared_helper
    template = generated_rack_attack_template
    phone_login = template[%r{^Rack::Attack\.throttle\("bih/phone-login/phone".*?^end$}m]
    sms_discriminator = template[/^sms_authorization_phone = lambda do \|request\|.*?^end$/m]

    refute_nil phone_login
    refute_nil sms_discriminator
    [phone_login, sms_discriminator].each do |rule|
      assert_includes rule, "Decidim::Bih::Throttling.phone_key("
      refute_includes rule, "Digest::SHA256.hexdigest(",
                      "the key recipe lives in Decidim::Bih::Throttling, not inlined per rule"
    end
  end

  def test_required_public_throttles_omit_short_magic_link_when_disabled
    throttles = Decidim::Bih.required_public_throttles_for_mount(
      mount_path: "/moja-platforma",
      short_magic_links: false
    )
    magic_link = throttles.find { |throttle| throttle.fetch(:id) == "magic_links.consume" }

    assert_equal ["/moja-platforma/v/:token"], magic_link.fetch(:paths)
  end

  def test_required_public_throttles_expand_for_root_mount_path_without_double_slashes
    throttles = Decidim::Bih.required_public_throttles_for_mount(mount_path: "/")
    chat = throttles.find { |throttle| throttle.fetch(:id) == "chat.create" }
    chat_feedback = throttles.find { |throttle| throttle.fetch(:id) == "chat.feedback" }
    corroborate = throttles.find { |throttle| throttle.fetch(:id) == "reports.corroborate" }
    infobip_chat = throttles.find { |throttle| throttle.fetch(:id) == "infobip-chat.webhook" }

    assert_equal ["/chat"], chat.fetch(:paths)
    assert_equal ["/chat/feedback"], chat_feedback.fetch(:paths)
    assert_equal ["\\A/prijave/[^/]+/potvrdi\\z"], corroborate.fetch(:path_regexes)
    assert_equal %w(/whatsapp/webhook /messenger/webhook /instagram/webhook), infobip_chat.fetch(:paths)
  end

  def test_public_write_route_classifications_cover_throttled_and_reviewed_routes
    routes = Decidim::Bih.required_public_write_routes
    ids = routes.map { |route| route.fetch(:id) }
    throttle_ids = Decidim::Bih.required_public_throttles.map { |throttle| throttle.fetch(:id) }

    assert_equal ids.sort, ids
    assert_equal ids.uniq, ids
    assert_includes ids, "komsiluk.suggest"
    assert_includes ids, "organizations.create"
    assert_includes ids, "community_projects.create"
    assert_includes ids, "community_projects.update"
    assert_includes ids, "contribution_needs.cancel"
    assert_includes ids, "contribution_offers.confirm"
    assert_includes ids, "infobip-chat.webhook"
    assert_includes ids, "volunteer.signup"
    assert_includes ids, "viber.webhook"
    assert_includes ids, "registration.create"
    assert_includes ids, "registration.change"
    assert_includes ids, "registration.code"
    assert_includes ids, "registration.resend"
    assert_includes ids, "registration.start_over"
    assert_includes ids, "registration.status"
    assert_includes ids, "sms_authorization.create"

    routes.each do |route|
      assert(route.fetch(:methods).all? { |method| %w(POST PATCH PUT DELETE).include?(method) })
      assert route.fetch(:auth).present?
      assert(route.has_key?(:path_template) || route.has_key?(:path_templates))

      route.fetch(:throttle_ids).each do |throttle_id|
        assert_includes throttle_ids, throttle_id
      end

      next if route.fetch(:throttle_ids).any?

      assert route.fetch(:no_throttle_reason).present?,
             "#{route.fetch(:id)} must explain why it has no dedicated throttle"
    end
  end

  def test_platform_receipt_route_declares_its_bounded_signed_capability
    route = Decidim::Bih.required_public_write_routes_for_mount(mount_path: "/moja-platforma")
                        .find { |item| item.fetch(:id) == "platform_delivery.acknowledge" }
    assert_equal ["POST"], route.fetch(:methods)
    assert_equal ["/moja-platforma/platform-receipt"], route.fetch(:paths)
    assert_equal "expiring_signed_delivery_capability", route.fetch(:auth)
    assert_empty route.fetch(:throttle_ids)
    assert_includes route.fetch(:no_throttle_reason), "2048-byte"
    assert_includes route.fetch(:no_throttle_reason), "cannot send messages or create rows"
  end

  def test_public_write_route_classifications_expand_for_custom_mount_path
    routes = Decidim::Bih.required_public_write_routes_for_mount(mount_path: "/moja-platforma")
    suggest = routes.find { |route| route.fetch(:id) == "komsiluk.suggest" }
    magic_link = routes.find { |route| route.fetch(:id) == "magic_links.consume" }
    project_create = routes.find { |route| route.fetch(:id) == "community_projects.create" }
    offer_deliver = routes.find { |route| route.fetch(:id) == "contribution_offers.deliver" }
    infobip_chat = routes.find { |route| route.fetch(:id) == "infobip-chat.webhook" }

    assert_equal ["/moja-platforma/komsiluk/suggest"], suggest.fetch(:paths)
    assert_equal ["komsiluk.suggest_by_ip", "komsiluk.suggest_by_session"], suggest.fetch(:throttle_ids)
    assert_equal ["/v/:token", "/moja-platforma/v/:token"], magic_link.fetch(:paths)
    assert_equal ["/moja-platforma/projekti"], project_create.fetch(:paths)
    assert_equal %w(community_contributions.write_by_ip community_contributions.write_by_session),
                 project_create.fetch(:throttle_ids)
    assert_equal ["/moja-platforma/volontiranje/ponude/:id/isporuceno"], offer_deliver.fetch(:paths)
    assert_equal %w(
      /moja-platforma/whatsapp/webhook
      /moja-platforma/messenger/webhook
      /moja-platforma/instagram/webhook
    ), infobip_chat.fetch(:paths)
    assert_equal ["infobip-chat.webhook"], infobip_chat.fetch(:throttle_ids)
  end

  def test_host_contract_manifest_combines_assets_and_throttles
    manifest = Decidim::Bih.host_contract_manifest(mount_path: "moj-grad", short_magic_links: false)
    magic_link = manifest.fetch(:required_public_throttles).find { |throttle| throttle.fetch(:id) == "magic_links.consume" }
    public_write = manifest.fetch(:required_public_write_routes).find { |route| route.fetch(:id) == "komsiluk.suggest" }

    assert_equal "/moj-grad", manifest.fetch(:public_mount_path)
    assert_equal false, manifest.fetch(:magic_link_short_path_enabled)
    assert_equal Decidim::Bih.required_public_assets.size, manifest.fetch(:required_public_assets).size
    assert_equal Decidim::Bih.required_public_throttles.size, manifest.fetch(:required_public_throttles).size
    assert_equal Decidim::Bih.required_public_write_routes.size, manifest.fetch(:required_public_write_routes).size
    assert_equal Decidim::Bih.required_public_surfaces_for_mount(mount_path: "moj-grad").size,
                 manifest.fetch(:required_public_surfaces).size
    assert_equal Decidim::Bih.required_brand_asset_reviews.size,
                 manifest.fetch(:required_brand_asset_reviews).size
    assert_equal Decidim::Bih.required_audit_event_streams.size,
                 manifest.fetch(:privacy_audit_contract).fetch(:audit_event_streams).size
    assert_equal ["/moj-grad/v/:token"], magic_link.fetch(:paths)
    assert_equal ["/moj-grad/komsiluk/suggest"], public_write.fetch(:paths)
  end

  private

  def generated_rack_attack_template
    File.read(
      File.expand_path("../../../../lib/generators/decidim/bih/templates/decidim_bih_rack_attack.rb.erb", __dir__)
    )
  end

  def assert_valid_throttle_limits(throttles)
    assert(throttles.all? { |throttle| throttle.fetch(:limit).positive? })
    assert(throttles.all? { |throttle| throttle.fetch(:period).positive? })
  end

  # GET is allowed only for a contract no public write route claims, so a
  # throttle that guards a declared write route cannot quietly acquire one.
  # The single exception is declared, not inherited: a contract that genuinely
  # covers a read AND a write of the same surface — the verification poll,
  # whose signed-in variant is a GET and whose registration variant is a POST
  # that can sign a browser in — says so in :read_methods_reason. And that
  # escape hatch may only appear where it is needed.
  def assert_valid_throttle_methods(throttles)
    write_throttle_ids = Decidim::Bih.required_public_write_routes.flat_map { |route| route.fetch(:throttle_ids) }.uniq

    throttles.each do |throttle|
      guards_a_write = write_throttle_ids.include?(throttle.fetch(:id))
      reason = throttle[:read_methods_reason]
      allowed = %w(POST PUT PATCH DELETE)
      allowed += ["GET"] if !guards_a_write || reason.present?

      throttle.fetch(:methods).each do |method|
        assert_includes allowed, method, "#{throttle.fetch(:name)} declares #{method}"
      end

      next if reason.blank?

      assert guards_a_write && throttle.fetch(:methods).include?("GET"),
             "#{throttle.fetch(:name)} explains a read method it does not need to explain"
    end
  end

  def assert_valid_throttle_discriminators(throttles)
    assert(throttles.all? { |throttle| %w(ip phone session).include?(throttle.fetch(:discriminator)) })
  end

  def assert_valid_throttle_paths(throttles)
    assert(
      throttles.all? do |throttle|
        throttle.has_key?(:path_template) || throttle.has_key?(:path_templates) || throttle.has_key?(:path_regex_template)
      end
    )
  end
end
