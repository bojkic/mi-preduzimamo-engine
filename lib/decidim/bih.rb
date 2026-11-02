# frozen_string_literal: true

require "active_support/configurable"
require "fileutils"
require "decidim/bih/version"
require "decidim/bih/transliterator"
require "decidim/bih/report_search_text"
require "decidim/bih/report_lifecycle"
require "decidim/bih/redaction"
require "decidim/bih/safe_error_metadata"
require "decidim/bih/redis_endpoint"
require "decidim/bih/instrumentation"
require "decidim/bih/provider_contracts"
require "decidim/bih/privacy_audit_contracts"
require "decidim/bih/task_send_modes"
require "decidim/bih/config"
require "decidim/bih/engine"
require "decidim/bih/admin_engine"

module Decidim
  module Bih
    include ActiveSupport::Configurable

    # Explicit adapter for an isolated local demo. Provider readiness continues
    # to use Infobip::Client itself and must never be claimed by this adapter.
    config_accessor(:phone_auth_demo_client_factory) { nil }

    def self.phone_auth_delivery_client
      factory = phone_auth_demo_client_factory
      return Decidim::Bih::Infobip::Client.new unless factory

      unless ENV["MI_INSTALL_PROFILE"] == "demo" && ENV["MI_LOCAL_HTTP"] == "true" && ENV["MI_DEMO_PHONE_CAPTURE"] == "true"
        raise ArgumentError, "Demo authentication transport requires explicit local demo profile"
      end

      client = factory.call
      raise ArgumentError, "Authentication demo transport must identify as simulated" unless client.respond_to?(:simulated?) && client.simulated?

      client
    end

    config_accessor(:report_reply_mailbox) { nil }
    config_accessor(:report_mail_transport) { "relay" }

    LOCALES = %w(sr sr-Cyrl bs hr).freeze

    # Referrer-Policy for token-bearing and private pages (verify link, pending
    # registration, phone sign-in, e-mail confirmation, "my reports").
    # "strict-origin" keeps the path — and any token in it — out of every
    # Referer header, same-origin ones included, while the browser still names
    # its origin. It must NOT be "no-referrer": the Fetch standard makes a
    # browser send `Origin: null` on every non-GET request from a no-referrer
    # page, and Rails' forgery_protection_origin_check then rejects each form
    # on it with 422 InvalidAuthenticityToken. That is exactly what happened on
    # 2026-09-09 once nginx stopped masking the upstream header: every code
    # entry, resend, verify-link confirm and phone sign-in failed for 16 hours.
    PRIVATE_PAGE_REFERRER_POLICY = "strict-origin"

    config_accessor(:map_default_center) { [43.9159, 17.6791] }
    config_accessor(:map_default_zoom) { 9 }
    config_accessor(:donations_provider) { nil }
    config_accessor(:public_support_email) { nil }
    config_accessor(:public_support_name) { nil }
    # The operating organisation's PUBLISHED postal address and website, as a
    # citizen would find them on the platform's own legal pages. Milica quotes
    # these when asked how to reach the organisation, and quotes nothing when
    # they are unset — an organisation with no published phone is told so,
    # never handed a municipality switchboard with a substituted label.
    config_accessor(:public_support_address) { nil }
    config_accessor(:public_support_website) { nil }
    # WHO PAYS FOR THIS PLATFORM, in the deployment's own reviewed words — a
    # String, or a callable taking +locale:+ and returning one. Milica quotes it
    # verbatim when a citizen asks who funds the platform and quotes nothing
    # when it is unset: the funder credit is a grant obligation and a
    # deployment's own fact, so the engine must never compose, shorten or guess
    # one. See the host's docs/operations/FUNDER_VISIBILITY.md.
    config_accessor(:public_funding_statement) { nil }
    # WHERE A CITIZEN SUBMITS A PROPOSAL: a path String, or a callable
    # returning one (a host that resolves a component path from the database
    # passes a lambda so the lookup happens per turn, not at boot). Unset means
    # the reviewed answer is not given at all rather than pointing somewhere
    # that may not accept proposals.
    config_accessor(:proposal_path) { nil }
    config_accessor(:mz_directory_source_label) { nil }
    config_accessor(:city_data_freshness_provider) { nil }
    config_accessor(:city_data_preview_provider) { nil }
    config_accessor(:admin_navigation_provider) { nil }
    # Authorized contextual links for the private Komšiluk board.
    config_accessor(:komsiluk_board_context_provider) { nil }
    # Citizen-safe host resolver: call(organization:, post:) returns
    # { updating: true/false, url: current_same_origin_path_or_nil }. It must
    # check tenant and current public visibility without operator permissions.
    config_accessor(:komsiluk_notice_public_source_provider) { nil }
    # Host callable `->(organization:) { [String, ...] }` appended to the weekly
    # analytics digest (Admin::AnalyticsDigestMailer#host_reminder_lines):
    # aggregate operational reminders such as "a content review expires in N
    # days", never citizen data. nil or [] adds nothing.
    config_accessor(:analytics_digest_reminders_provider) { nil }
    config_accessor(:concierge_resolver) { nil }
    config_accessor(:external_chat_onboarding_links) { {} }
    # Owner decision D12: the newsletter is MI's, and Odoo owns donors. The
    # BOUNDARY half of that is unconditional (see NewsletterEligibility); this
    # switch governs only the narrowing to PROVEN current addresses, which
    # removes people from a list they are on today and therefore defaults off.
    # Boot-read: changing it needs a Puma and Sidekiq restart.
    config_accessor(:newsletter_verified_audience) { false }
    config_accessor(:goodwill_earning_schedule) { nil }
    # Hosts opt into dated volunteering awards at the coordinated cutover.
    # The defaults preserve the shared engine's historical units.
    config_accessor(:volunteer_work_award_unit) { :hour }
    config_accessor(:volunteer_proposal_award_unit) { :term }
    config_accessor(:goodwill_daily_caps) { nil }
    config_accessor(:goodwill_rewards_catalog) { nil }
    config_accessor(:goodwill_season_started_at) { nil }
    # Hosts opt into manual review. The shared engine keeps explicit automatic
    # acceptance until the host completes its legacy-seat reconciliation.
    config_accessor(:volunteer_application_review_required) { false }
    # Trka komšiluka (6.9.–14.10.2026). Defaults live in
    # Decidim::Bih::Race::Config; these let the host app move the window,
    # the weights and the per-person caps without touching engine code.
    config_accessor(:race_window_from) { nil }
    config_accessor(:race_window_to) { nil }
    config_accessor(:race_weights) { nil }
    config_accessor(:race_caps) { nil }
    # Launch invitation waves (Task 10). The client settled on 310 invitations
    # in one wave opening 6.9.2026, but the schedule stays a LIST of waves so
    # restoring the original multi-wave plan is a config change, not a code
    # change. See Decidim::Bih::Launch::InvitationWaves.
    config_accessor(:launch_invitation_waves) { nil }
    # Which messaging policy runs, per message class. A Hash of
    # "<message class>" => "legacy" | "compatibility" | "target", optionally
    # with a "default" key. Nil means every class stays on `legacy`, and a
    # producer that is not enrolled in Messaging::MessageClass can never be
    # moved off legacy by a flag at all. Per-organization overrides live in the
    # Decidim::Bih::Setting namespace "messaging"; see Messaging::Modes for the
    # read path and its latency.
    config_accessor(:messaging_modes) { nil }
    # Quiet hours and routine budgets are INERT until a host sets them.
    #
    # `nil` means "send now", which is today's behaviour on every message class.
    # Owner decision D8 is 21:00-08:00 Europe/Sarajevo for `routine` priority
    # only — `authentication` (D8 calls it `critical`) and `transactional`
    # (`important`) bypass entirely — and that window is recorded in code as
    # `Messaging::Priority::D8_QUIET_HOURS`. Activating it means setting this
    # accessor to that hash in a host initializer AND restarting Puma and
    # Sidekiq, because a `config_accessor` is boot-read. See
    # `Messaging::Priority` for the DST, expiry and starvation rules the window
    # obeys once it is set.
    #
    # `routine_budgets` maps a message-class key (or "default") to
    # `{ max_messages:, max_cost:, period_seconds: }`. An exhausted budget is a
    # DELAY within the message's own lifetime, never a refusal.
    config_accessor(:routine_quiet_hours) { nil }
    config_accessor(:routine_budgets) { {} }
    config_accessor(:launch_invitation_reward_key) { "pozivnica_lansiranje" }
    config_accessor(:pwa_short_name) { nil }
    config_accessor(:viber_bot_uri) { nil }
    config_accessor(:viber_public_onboarding_enabled) { false }
    config_accessor(:geocoder_user_agent) do
      "DecidimBih/1.0 (+https://github.com/bojkic/decidim-bih; komsiluk geocoding)"
    end
    config_accessor(:geocoder_base_url) { nil }
    config_accessor(:geocoder_search_path) { "/search" }
    config_accessor(:geocoder_extra_headers) { {} }
    # Optional host-local address/area candidate lookup; never receives user records.
    config_accessor(:local_address_lookup) { nil }
    config_accessor(:default_host) { "localhost" }
    config_accessor(:infobip_sms_sender) { nil }
    config_accessor(:reporter_mailer_from) { "notifications@example.org" }

    # Owner decision D11 (2026-09-14): a MONITORED reply mailbox, not just a
    # From address. Nil by default so the reusable engine never points another
    # host's replies at somebody else's inbox; the host sets it.
    #
    # Core SMTP gets this value before its sender fallback; the delivery
    # interceptor supplies it for non-core mailers. Explicit reply addresses
    # are preserved on both paths.
    config_accessor(:mailer_reply_to) { nil }
    config_accessor(:sistem48_mailer_from) { "reports@example.org" }
    config_accessor(:sistem48_central_intake) { nil }
    config_accessor(:sistem48_archive_url) { nil }
    config_accessor(:sistem48_forwarded_via_name) { "Decidim BIH platforme" }
    # Unattended intake requires both auto-forward and an explicit opt-out
    # from staff review. AI activation never changes this policy.
    config_accessor(:sistem48_auto_forward) { true }
    config_accessor(:report_review_first) { true }
    config_accessor(:public_mount_path) { "/biceriseno" }
    config_accessor(:magic_link_short_path_enabled) { true }
    config_accessor(:flagship_process_slug) { nil }
    config_accessor(:mi_hub_decision_path) { nil }
    config_accessor(:campaign_hashtag) { nil }
    # Phone-first registration (Bijeljina launch decision, 2026-09-05):
    # accounts are activated without e-mail confirmation, the phone is the
    # verified identity, and e-mail is confirmed separately for recovery.
    # Hosts opt in; the engine default keeps stock Decidim behaviour.
    config_accessor(:phone_first_registration) { false }
    # Opt-in name + phone signup; geography follows proof of the phone.
    config_accessor(:simplified_registration) { false }
    # Accounts whose confirmed_at predates this instant went through the
    # Devise e-mail link (or an admin) and count as e-mail-confirmed.
    # nil means "no cutoff": every confirmed_at is treated as proven.
    config_accessor(:phone_first_registration_since) { nil }
    # Where every "register" link points. Delivery D switches this to the
    # engine's one-step form; until then the Decidim form, and a host running
    # a launch-mode landing page sends citizens somewhere else again.
    #
    # Two consumers, and a host that moves this moves both at once: the
    # engine's own launch surfaces (hero CTAs, the omni band, the onboarding
    # guide, Milica's registration prompt) render it as a destination, and the
    # host's social-registration handoff reads it as a sentinel to decide
    # where an omniauth sign-up that still needs an account lands.
    config_accessor(:registration_path) { "/users/sign_up" }
    config_accessor(:registration_newsletter_default) { false }
    # When set (e.g. "/registracija") the host serves the one-step
    # registration at that root path and the engine builds registration URLs
    # from it; nil = engine-mounted path. Delivery D's host route lives
    # outside the engine mount, mirroring how registration_path lets a host
    # move the "register" destination without an engine code change.
    config_accessor(:registration_base_path) { nil }
    # Short, sayable invite link. nil = the invite link is the registration
    # form with ?ref=<nadimak>. A host that sets this (e.g. "/p") declares the
    # matching root route to Decidim::Bih::InviteLinksController#short and the
    # shared link becomes <base>/p/<nadimak>; the engine mount answers the same
    # path under /biceriseno either way. Read through .invite_short_path_for.
    config_accessor(:invite_short_path) { nil }
    # nil = the cell's default three buttons. Hosts pass an array of
    # { label_key:, href: (String | :registration), style: "primary"|"ghost", chat: true|false },
    # or a Proc returning one (so the list can be decided per request rather
    # than frozen at boot).
    #
    # An href: :registration button follows registration_path for a visitor and
    # the account page for a signed-in citizen. Give such a button an optional
    # signed_in_label_key: so its LABEL follows too — without it an already
    # registered citizen is invited to "Registruj se" and lands on /moj-doprinos.
    config_accessor(:mi_hero_ctas) { nil }
    # Stat tiles whose value is below this are not rendered (an empty-looking
    # platform is worse than a shorter strip). Integer, or a Proc returning one.
    config_accessor(:mi_hero_stat_min) { 0 }

    def self.phone_first_registration_cutoff
      raw = phone_first_registration_since
      return nil if raw.blank?
      return raw.utc if raw.respond_to?(:utc)

      Time.find_zone!("UTC").parse(raw.to_s)&.utc
    end

    config_accessor(:mi_bot_sms_shortcode) { nil }
    config_accessor(:mi_bot_showcase_assistant_name) { "asistent platforme" }
    config_accessor(:mi_bot_showcase_sticker_text) { "PREUZIMAMO" }
    # Optional host-owned Komšinica Milica visual. The reusable engine never
    # assumes these files exist; configured hosts provide both motion and
    # reduced-motion-safe variants from their public asset boundary.
    config_accessor(:mi_bot_persona_image_path)
    config_accessor(:mi_bot_persona_static_image_path)
    config_accessor(:mi_bot_demo_city_accusative) { "svoj grad" }
    config_accessor(:mi_bot_demo_street) { "Glavna ulica" }
    config_accessor(:mi_bot_demo_address) { "Glavna ulica" }
    config_accessor(:mi_bot_demo_destination) { "rijeke" }
    config_accessor(:mi_bot_demo_proposal_title) { "Biciklisticka staza" }
    # No hardcoded default (2026-08-31): this used to default to "600.000 KM",
    # the exact figure a client retracted elsewhere in a host deployment. A
    # generic reusable engine has no business defaulting to any specific KM
    # claim; a host that wants this showcase field populated sets its own.
    config_accessor(:mi_bot_demo_budget_amount)
    config_accessor(:mi_bot_demo_budget_items) do
      [["Novi park u naselju", "240.000"], ["Uredenje setalista", "180.000"]]
    end
    config_accessor(:mi_bot_demo_donation_title) { "Uredimo setaliste" }

    # Host donation providers may be bound to one Decidim organization. The
    # optional +available_for?+ capability lets generic engine surfaces fail
    # closed instead of leaking one tenant's aggregate totals or checkout URL
    # into another tenant. Providers without the capability retain the original
    # globally-available behavior for backwards compatibility.
    def self.donations_provider_available_for?(provider, organization:)
      return false unless provider
      return true unless provider.respond_to?(:available_for?)

      availability = provider.method(:available_for?)
      keyword_capable = availability.parameters.any? do |type, _name|
        [:key, :keyreq, :keyrest].include?(type)
      end
      keyword_capable ? availability.call(organization:) : availability.call(organization)
    rescue StandardError
      false
    end

    def self.donations_provider_for(organization:)
      provider = donations_provider
      provider if donations_provider_available_for?(provider, organization:)
    end

    REQUIRED_PUBLIC_ASSETS = [
      "/leaflet/leaflet.css",
      "/leaflet/leaflet.js",
      "/leaflet/images/layers-2x.png",
      "/leaflet/images/layers.png",
      "/leaflet/images/marker-icon-2x.png",
      "/leaflet/images/marker-icon.png",
      "/leaflet/images/marker-shadow.png",
      "/mi/bih-komsiluk-map.js",
      "/mi/komsiluk-board.css",
      "/mi/komsiluk-board.js",
      "/mi/bih-mz-map.js",
      "/mi/bih-report-location-map.js",
      "/mi/bih-reports-map.js",
      "/mi/heart-mark.png",
      "/mi/mi-bot.css",
      "/mi/mi-chat-loader.js",
      "/mi/mi-chat.css",
      "/mi/mi-chat.js",
      "/mi/mi-fonts.css",
      "/mi/mi-install.js",
      "/mi/mi-theme.css",
      "/mi/fonts/1Ptvg83HX_SGhgqk0AotcqA.woff2",
      "/mi/fonts/1Ptvg83HX_SGhgqk0QotcqA.woff2",
      "/mi/fonts/1Ptvg83HX_SGhgqk0gotcqA.woff2",
      "/mi/fonts/1Ptvg83HX_SGhgqk2wotcqA.woff2",
      "/mi/fonts/1Ptvg83HX_SGhgqk3wot.woff2",
      "/mi/fonts/1Ptwg83HX_SGhgqk2hAjQlW_mEuZ0FsSKeOfF5Q6HTY.woff2",
      "/mi/fonts/1Ptwg83HX_SGhgqk2hAjQlW_mEuZ0FsSKeOfFJQ6HTY.woff2",
      "/mi/fonts/1Ptwg83HX_SGhgqk2hAjQlW_mEuZ0FsSKeOfFpQ6HTY.woff2",
      "/mi/fonts/1Ptwg83HX_SGhgqk2hAjQlW_mEuZ0FsSKeOfGZQ6.woff2",
      "/mi/fonts/1Ptwg83HX_SGhgqk2hAjQlW_mEuZ0FsSKeOfHZQ6HTY.woff2",
      "/mi/fonts/92zJtBhPNqw73oHH7BbQp4-B6XlrZu0FBI4knsHL.woff2",
      "/mi/fonts/92zJtBhPNqw73oHH7BbQp4-B6XlrZu0FBIQknsHL.woff2",
      "/mi/fonts/92zJtBhPNqw73oHH7BbQp4-B6XlrZu0FBIokng.woff2",
      "/mi/fonts/92zatBhPNqw73oDd4iYl.woff2",
      "/mi/fonts/92zatBhPNqw73oTd4g.woff2",
      "/mi/fonts/92zatBhPNqw73ord4iYl.woff2",
      "/mi/stickers/bravo.png",
      "/mi/stickers/glas.png",
      "/mi/stickers/hvala.png",
      "/mi/stickers/podrzano.png",
      "/mi/stickers/preuzimamo.png",
      "/mi/stickers/prijavljeno.png",
      "/mi/stickers/rijeseno.png",
      "/mi/stickers/stize.png",
      "/mi/stickers/volim.png"
    ].sort.freeze

    PUBLIC_SURFACE_REVIEW_ITEMS = [
      {
        id: "reports.root",
        route_helper: "root_path",
        methods: ["GET"],
        path_template: "{mount}",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.reports",
        host_review_flags: %w(report_intake_copy local_issue_categories sistem48_routing),
        privacy_boundary: "Report intake may collect citizen PII; public status output must stay PII-light."
      },
      {
        id: "reports.new",
        route_helper: "new_report_path",
        methods: ["GET"],
        path_template: "{mount}/prijave/new",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.reports",
        host_review_flags: %w(report_form_copy map_defaults photo_rules duplicate_guidance),
        privacy_boundary: "The form may collect contact, address, coordinate and photo data; do not expose it in public review surfaces."
      },
      {
        id: "reports.index",
        route_helper: "reports_path",
        methods: ["GET"],
        path_template: "{mount}/prijave",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.reports_tracker",
        host_review_flags: %w(status_labels report_reference_policy public_tracker_copy),
        privacy_boundary: "Tracker rows use public lifecycle data only; keep private details behind reports.status_token."
      },
      {
        id: "reports.status_token",
        route_helper: "report_status_path",
        methods: ["GET"],
        path_template: "{mount}/prijave/:reference/status/:status_token",
        visibility: "private_link",
        lifecycle: "private_token",
        public_nav: false,
        menu_i18n_key: nil,
        host_review_flags: %w(status_labels reporter_notification_copy private_detail_boundary),
        privacy_boundary: "Reporter-owned status links use an unguessable token; do not expose status tokens in public indexes, maps, analytics or generated evidence."
      },
      {
        id: "reports.show",
        route_helper: "report_path",
        methods: ["GET"],
        path_template: "{mount}/prijave/:reference",
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(status_labels reporter_notification_copy public_detail_boundary),
        privacy_boundary: "Sequential references remain public only for the PII-light tracker; use reports.status_token before exposing private reporter details."
      },
      {
        id: "reports_map.show",
        route_helper: "reports_map_path",
        methods: ["GET"],
        path_templates: ["{mount}/mapa", "{mount}/mapa.json"],
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.reports_map",
        host_review_flags: %w(map_center map_tiles geojson_cache sparse_location_privacy),
        privacy_boundary: "Map output must avoid report contacts, descriptions and exact private reporter details."
      },
      {
        id: "report_heatmap.index",
        route_helper: "report_heatmap_path",
        methods: ["GET"],
        path_template: "{mount}/mapa-problema",
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(local_area_boundaries sparse_cell_suppression category_labels),
        privacy_boundary: "Heatmap output is aggregate-only and must preserve sparse-cell suppression."
      },
      {
        id: "donations.show",
        route_helper: "donations_path",
        methods: ["GET"],
        path_template: "{mount}/donacije",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.donations",
        host_review_flags: %w(donation_provider donate_url currency_label campaign_mapping),
        privacy_boundary: "Donation surfaces use aggregate totals and must not expose donor identities or payment references."
      },
      {
        id: "community_projects.index",
        route_helper: "community_projects_path",
        methods: ["GET"],
        path_template: "{mount}/projekti",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.projects",
        host_review_flags: %w(project_copy donation_provider fundraising_goal partner_attribution),
        privacy_boundary: "Only LFBN-approved native projects and aggregate contribution context are public; draft submissions and reviewer notes stay private."
      },
      {
        id: "community_projects.new",
        route_helper: "new_community_project_path",
        methods: ["GET"],
        path_template: "{mount}/projekti/novi",
        visibility: "signed_in",
        lifecycle: "moderated_submission",
        public_nav: false,
        menu_i18n_key: nil,
        host_review_flags: %w(project_submission_copy verified_partner_gate funding_goal campaign_key_exclusion),
        privacy_boundary: "Project drafts are visible only to their verified partner representative and LFBN reviewers until approval."
      },
      {
        id: "community_projects.show",
        route_helper: "community_project_path",
        methods: ["GET"],
        path_template: "{mount}/projekti/:id",
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(project_copy donation_provider volunteer_links contribution_needs),
        privacy_boundary: "The approved project is a durable public transparency record; fundraising and help follow " \
                          "current eligibility, while offer identities and reviewer notes stay private."
      },
      {
        id: "impact.index",
        route_helper: "impact_path",
        methods: ["GET"],
        path_template: "{mount}/uticaj",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.impact",
        host_review_flags: %w(public_metrics sparse_cell_suppression editorial_copy),
        privacy_boundary: "Impact metrics are aggregate-only and must not reveal local membership or private content."
      },
      {
        id: "mi_bot.show",
        route_helper: "mi_bot_path",
        methods: ["GET"],
        path_template: "{mount}/mi-bot",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.mi_bot",
        host_review_flags: %w(bot_name channel_copy demo_city_data viber_launch_state),
        privacy_boundary: "Bot review surfaces may persist rated prompt/reply pairs only after helpful/not-helpful feedback and must not attach them to a user account."
      },
      {
        id: "community_hub.show",
        route_helper: "community_hub_path",
        methods: ["GET"],
        path_template: "{mount}/zajednistvo",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.community_hub",
        host_review_flags: %w(points_vocabulary reward_catalog recognition_policy vote_weight_copy),
        privacy_boundary: "Goodwill copy must state that points do not affect votes, proposal visibility or ranking."
      },
      {
        id: "wallet.show",
        route_helper: "wallet_path",
        methods: ["GET"],
        path_template: "{mount}/moj-doprinos",
        visibility: "signed_in",
        lifecycle: "private_account",
        public_nav: false,
        menu_i18n_key: "decidim.bih.menu.wallet",
        host_review_flags: %w(wallet_copy monthly_statement_copy shared_device_privacy),
        privacy_boundary: "Wallet and statement data are private signed-in surfaces."
      },
      {
        id: "gifts.index",
        route_helper: "gifts_path",
        methods: ["GET"],
        path_template: "{mount}/podrzi",
        visibility: "signed_in",
        lifecycle: "private_account",
        menu_i18n_key: nil,
        host_review_flags: %w(gift_policy organization_regrant_copy points_not_money_copy),
        privacy_boundary: "Gift/regrant surfaces must not describe points as money, donations or voting power."
      },
      {
        id: "organizations.index",
        route_helper: "organizations_path",
        methods: ["GET"],
        path_template: "{mount}/organizacije",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.organizations",
        host_review_flags: %w(local_organization_copy verification_workflow public_member_transparency),
        privacy_boundary: "Only verified profiles are public; accepted members are public by owner decision, private contact fields are admin-only."
      },
      {
        id: "organizations.show",
        route_helper: "organization_path",
        methods: ["GET"],
        path_template: "{mount}/organizacija/:id",
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(local_organization_copy regrant_policy group_profile_copy),
        privacy_boundary: "Organization pages may show aggregate point context, not private member wallet details."
      },
      {
        id: "volunteer.index",
        route_helper: "volunteer_path",
        methods: ["GET"],
        path_template: "{mount}/volontiranje",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.volunteer",
        host_review_flags: %w(volunteer_policy hour_award_copy partner_workflow capacity_rules contribution_needs offer_confirmation),
        privacy_boundary: "Volunteer and non-cash need flows expose approved calls only; availability, attendance notes, offer identities and review reasons stay private."
      },
      {
        id: "komsiluk.edit",
        route_helper: "edit_komsiluk_path",
        methods: ["GET"],
        path_template: "{mount}/komsiluk",
        visibility: "signed_in",
        lifecycle: "private_account",
        public_nav: false,
        menu_i18n_key: "decidim.bih.menu.komsiluk",
        host_review_flags: %w(local_area_geojson geocoder_provider address_copy private_assignment_copy),
        privacy_boundary: "Citizen neighbourhood assignment is private profile data, not public profile data."
      },
      {
        id: "komsiluk_board.index",
        route_helper: "komsiluk_board_index_path",
        methods: ["GET"],
        path_template: "{mount}/komsiluk-board",
        visibility: "public",
        menu_i18n_key: "decidim.bih.menu.komsiluk_board",
        host_review_flags: %w(board_categories moderation_policy urgent_notification_policy),
        privacy_boundary: "Board moderation and analytics must not expose membership lists or recipient lists."
      },
      {
        id: "mz_directory.index",
        route_helper: "mz_directory_path",
        methods: ["GET"],
        path_template: "{mount}/mjesne-zajednice",
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(local_area_names contact_publication_policy boundary_assets),
        privacy_boundary: "Directory pages use public local-area records and boundary data only."
      },
      {
        id: "mz_directory.show",
        route_helper: "mz_area_path",
        methods: ["GET"],
        path_templates: ["{mount}/mjesne-zajednice/:slug", "{mount}/mjesne-zajednice/:slug.json"],
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(local_area_names boundary_geojson_cache contact_publication_policy),
        privacy_boundary: "Boundary GeoJSON must not include citizen addresses, assignments or membership data."
      },
      {
        id: "phone_sessions.new",
        route_helper: "phone_login_path",
        methods: ["GET"],
        path_template: "{mount}/prijava",
        visibility: "public",
        menu_i18n_key: nil,
        host_review_flags: %w(phone_country_code sms_copy viber_fallback_copy rate_limit_copy),
        privacy_boundary: "Phone login surfaces must not leak normalized phone values or token state."
      },
      {
        id: "web_chat.create",
        route_helper: "web_chat_path",
        methods: ["POST"],
        path_template: "{mount}/chat",
        visibility: "same_origin_endpoint",
        lifecycle: "write_endpoint",
        public_nav: false,
        menu_i18n_key: nil,
        host_review_flags: %w(concierge_provider city_data_answers feedback_metadata),
        privacy_boundary: "Web chat stores aggregate usage only until a helpful/not-helpful click signs consent to save that prompt/reply pair anonymously."
      }
    ].sort_by { |surface| surface.fetch(:id) }.freeze

    BRAND_ASSET_REVIEW_FAMILIES = [
      {
        id: "chat_and_install_helpers",
        public_paths: %w(/mi/mi-chat-loader.js /mi/mi-chat.js /mi/mi-chat.css /mi/mi-install.js),
        review_note: "Review widget copy, public base path fallbacks, install prompt wording and local channel names."
      },
      {
        id: "leaflet_vendor_assets",
        public_paths: %w(/leaflet/leaflet.css /leaflet/leaflet.js /leaflet/images/marker-icon.png),
        review_note: "Keep a compatible Leaflet distribution and marker image sidecars when replacing vendor assets."
      },
      {
        id: "map_helpers",
        public_paths: %w(/mi/bih-report-location-map.js /mi/bih-reports-map.js /mi/bih-komsiluk-map.js /mi/bih-mz-map.js),
        review_note: "Review map defaults, public JSON endpoints, local-area wording and privacy-preserving marker behavior."
      },
      {
        id: "mi_mark",
        public_paths: %w(/mi/heart-mark.png),
        review_note: "Replace the packaged mark with local branding while preserving the required public path."
      },
      {
        id: "stickers",
        public_paths: %w(/mi/stickers/bravo.png /mi/stickers/prijavljeno.png /mi/stickers/rijeseno.png),
        review_note: "Replace bot/Viber sticker art and text for the host brand before public channel launch."
      },
      {
        id: "theme_and_fonts",
        public_paths: %w(/mi/mi-theme.css /mi/mi-fonts.css),
        review_note: "Review colors, typography, spacing and font licensing for the host brand."
      }
    ].sort_by { |asset| asset.fetch(:id) }.freeze

    REQUIRED_DECIDIM_MODULES = [
      {
        id: "decidim_core",
        gem: "decidim-core",
        status: "hard_runtime_dependency",
        reason: "Base Decidim organization, user, admin, menu, content-block and engine integration APIs."
      },
      {
        id: "decidim_budgets",
        gem: "decidim-budgets",
        status: "hard_runtime_dependency",
        reason: "Budget checkout overrides award Goodwill points and the reference host links citizens into budgeting flows."
      },
      {
        id: "decidim_forms",
        gem: "decidim-forms",
        status: "hard_runtime_dependency",
        reason: "Meetings/forms constants are loaded by current Decidim module wiring and generated-host boot paths."
      },
      {
        id: "decidim_meetings",
        gem: "decidim-meetings",
        status: "hard_runtime_dependency",
        reason: "Meetings/forms module integration is loaded by the current Decidim stack during host boot."
      },
      {
        id: "decidim_proposals",
        gem: "decidim-proposals",
        status: "hard_runtime_dependency",
        reason: "Proposal vote and proposal publish overrides award Goodwill points and must load consistently."
      },
      {
        id: "decidim_verifications",
        gem: "decidim-verifications",
        status: "hard_runtime_dependency",
        reason: "SMS, phone-login, postal token, QR confirmation and verification-award flows depend on Decidim verification APIs."
      }
    ].sort_by { |mod| mod.fetch(:id) }.freeze

    REQUIRED_PUBLIC_THROTTLES = [
      {
        id: "chat.create",
        name: "bih/chat.create/ip",
        methods: ["POST"],
        path_template: "{mount}/chat",
        discriminator: "ip",
        limit: 30,
        period: 60
      },
      {
        id: "chat.feedback",
        name: "bih/chat.feedback/ip",
        methods: ["POST"],
        path_template: "{mount}/chat/feedback",
        discriminator: "ip",
        limit: 60,
        period: 60
      },
      {
        id: "community_contributions.write_by_ip",
        name: "bih/community-contributions.write/ip",
        methods: %w(POST PATCH),
        path_templates: [
          "{mount}/projekti",
          "{mount}/projekti/prijave/:id",
          "{mount}/volontiranje/potrebe",
          "{mount}/volontiranje/potrebe/:id/otkazi",
          "{mount}/volontiranje/potrebe/:need_id/ponude",
          "{mount}/volontiranje/ponude/:id/prihvati",
          "{mount}/volontiranje/ponude/:id/odbij",
          "{mount}/volontiranje/ponude/:id/povuci",
          "{mount}/volontiranje/ponude/:id/isporuceno",
          "{mount}/volontiranje/ponude/:id/potvrdi"
        ],
        discriminator: "ip",
        limit: 10,
        period: 60
      },
      {
        id: "community_contributions.write_by_session",
        name: "bih/community-contributions.write/session",
        methods: %w(POST PATCH),
        path_templates: [
          "{mount}/projekti",
          "{mount}/projekti/prijave/:id",
          "{mount}/volontiranje/potrebe",
          "{mount}/volontiranje/potrebe/:id/otkazi",
          "{mount}/volontiranje/potrebe/:need_id/ponude",
          "{mount}/volontiranje/ponude/:id/prihvati",
          "{mount}/volontiranje/ponude/:id/odbij",
          "{mount}/volontiranje/ponude/:id/povuci",
          "{mount}/volontiranje/ponude/:id/isporuceno",
          "{mount}/volontiranje/ponude/:id/potvrdi"
        ],
        discriminator: "session",
        limit: 60,
        period: 3600
      },
      {
        id: "email_confirmation.request_by_session",
        name: "bih/email-confirmation-request/session",
        methods: ["POST"],
        path_template: "{mount}/potvrdi-email",
        discriminator: "session",
        limit: 3,
        period: 900
      },
      {
        id: "infobip-chat.webhook",
        name: "bih/infobip-chat.webhook/ip",
        methods: ["POST"],
        path_templates: [
          "{mount}/whatsapp/webhook",
          "{mount}/messenger/webhook",
          "{mount}/instagram/webhook"
        ],
        discriminator: "ip",
        host_route: true,
        limit: 60,
        period: 60
      },
      {
        id: "komsiluk_board.write_by_ip",
        name: "bih/komsiluk-board.write/ip",
        methods: %w(POST PATCH PUT),
        path_templates: ["{mount}/komsiluk-board", "{mount}/komsiluk-board/:id/prijavi", "{mount}/komsiluk-board/:id/zatvori",
                         "{mount}/komsiluk-board/:id", "{mount}/komsiluk-board/:id/resolve", "{mount}/komsiluk-board/:id/help"],
        discriminator: "ip",
        limit: 5,
        period: 60
      },
      {
        id: "komsiluk_board.write_by_session",
        name: "bih/komsiluk-board.write/session",
        methods: %w(POST PATCH PUT),
        path_templates: ["{mount}/komsiluk-board", "{mount}/komsiluk-board/:id/prijavi", "{mount}/komsiluk-board/:id/zatvori",
                         "{mount}/komsiluk-board/:id", "{mount}/komsiluk-board/:id/resolve", "{mount}/komsiluk-board/:id/help"],
        discriminator: "session",
        limit: 10,
        period: 3600
      },
      {
        id: "komsiluk.suggest_by_ip",
        name: "bih/komsiluk.suggest/ip",
        methods: ["POST"],
        path_template: "{mount}/komsiluk/suggest",
        discriminator: "ip",
        limit: 20,
        period: 60
      },
      {
        id: "komsiluk.suggest_by_session",
        name: "bih/komsiluk.suggest/session",
        methods: ["POST"],
        path_template: "{mount}/komsiluk/suggest",
        discriminator: "session",
        limit: 60,
        period: 3600
      },
      {
        id: "magic_links.consume",
        name: "bih/magic-link",
        methods: ["POST"],
        path_templates: ["/v/:token", "{mount}/v/:token"],
        discriminator: "ip",
        host_route: true,
        limit: 10,
        period: 60
      },
      {
        id: "organizations.write_by_ip",
        name: "bih/organizations.write/ip",
        methods: %w(POST PATCH DELETE),
        path_templates: [
          "{mount}/organizacije",
          "{mount}/organizacije/:id",
          "{mount}/organizacija/:id/regrant",
          "{mount}/organizacija/:id/potrosnja",
          "{mount}/organizacija/:id/obavjestenja",
          "{mount}/organizacija/:id/clanovi",
          "{mount}/organizacija/:id/clanovi/:membership_id",
          "{mount}/organizacija/clanstvo/:membership_id/prihvati",
          "{mount}/organizacija/clanstvo/:membership_id/odbij",
          "{mount}/organizacija/clanstvo/:membership_id/napusti"
        ],
        discriminator: "ip",
        limit: 10,
        period: 60
      },
      {
        id: "organizations.write_by_session",
        name: "bih/organizations.write/session",
        methods: %w(POST PATCH DELETE),
        path_templates: [
          "{mount}/organizacije",
          "{mount}/organizacije/:id",
          "{mount}/organizacija/:id/regrant",
          "{mount}/organizacija/:id/potrosnja",
          "{mount}/organizacija/:id/obavjestenja",
          "{mount}/organizacija/:id/clanovi",
          "{mount}/organizacija/:id/clanovi/:membership_id",
          "{mount}/organizacija/clanstvo/:membership_id/prihvati",
          "{mount}/organizacija/clanstvo/:membership_id/odbij",
          "{mount}/organizacija/clanstvo/:membership_id/napusti"
        ],
        discriminator: "session",
        limit: 30,
        period: 3600
      },
      {
        id: "phone_login.code_by_ip",
        name: "bih/phone-login-code/ip",
        methods: ["POST"],
        path_template: "{mount}/prijava/kod",
        discriminator: "ip",
        limit: 10,
        period: 60
      },
      {
        id: "phone_login.request_by_ip",
        name: "bih/phone-login/ip",
        methods: ["POST"],
        path_template: "{mount}/prijava",
        discriminator: "ip",
        limit: 5,
        period: 900
      },
      {
        id: "phone_login.request_by_phone",
        name: "bih/phone-login/phone",
        methods: ["POST"],
        path_template: "{mount}/prijava",
        discriminator: "phone",
        limit: 3,
        period: 900
      },
      # The four phone-verification budgets below each cover TWO pages: the
      # signed-in verification page and the one-step registration's pending
      # page, which do the same thing for the same citizen. One budget across
      # both on purpose — a second one would only mean a second set of paid
      # messages and a second set of guesses for whoever rotates sessions.
      #
      # "/registracija" is the root path the reference host serves the one-step
      # form at (Decidim::Bih.registration_base_path); the mounted path is what
      # a host that leaves that unset serves. A host that moves the base to
      # some other root path extends its own rules — the generated initializer
      # reads the config and follows it automatically.
      {
        id: "phone_verification.change_by_session",
        name: "bih/phone-verification-change/session",
        # "Start over" throws a whole pending registration away, which is the
        # heavier version of the same "this number is wrong" move — one budget
        # covers both so neither can be used to walk around the other.
        methods: %w(DELETE POST),
        path_templates: [
          "{mount}/verifikacija/telefon",
          "/registracija/potvrda",
          "{mount}/registracija/potvrda",
          "/registracija/potvrda/pocni-ispocetka",
          "{mount}/registracija/potvrda/pocni-ispocetka"
        ],
        discriminator: "session",
        host_route: true,
        limit: 5,
        period: 900
      },
      {
        id: "phone_verification.code_by_session",
        name: "bih/phone-verification-code/session",
        methods: ["POST"],
        path_templates: [
          "{mount}/verifikacija/telefon/kod",
          "/registracija/potvrda/kod",
          "{mount}/registracija/potvrda/kod"
        ],
        discriminator: "session",
        host_route: true,
        limit: 10,
        period: 60
      },
      {
        id: "phone_verification.resend_by_session",
        name: "bih/phone-verification-resend/session",
        methods: ["POST"],
        path_templates: [
          "{mount}/verifikacija/telefon/ponovo",
          "/registracija/potvrda/ponovo",
          "{mount}/registracija/potvrda/ponovo"
        ],
        discriminator: "session",
        host_route: true,
        limit: 5,
        period: 900
      },
      {
        id: "phone_verification.status_by_session",
        name: "bih/phone-verification-status/session",
        methods: %w(GET POST),
        # One poll, two verbs. The signed-in page asks with a GET; the pending
        # page asks with a POST, because that one can sign the waiting browser
        # in and no state-changing endpoint may be reachable as a GET (R-D4).
        # A throttle that guards a declared write route normally may not carry
        # a GET at all — this one says why it does rather than acquiring it
        # quietly (see PublicThrottlesTest#assert_valid_throttle_methods).
        read_methods_reason: "The signed-in verification page polls the same budget with a GET; " \
                             "only the registration variant is a write.",
        path_templates: [
          "{mount}/verifikacija/telefon/status",
          "/registracija/potvrda/status",
          "{mount}/registracija/potvrda/status"
        ],
        discriminator: "session",
        host_route: true,
        limit: 30,
        period: 60
      },
      {
        id: "registration.create",
        name: "bih/registration-create/ip",
        methods: ["POST"],
        # Decidim's own sign-up and the one-step form share the ceiling: they
        # are two doors into the same room, and a flood through either buys
        # nothing without a verified phone behind each account.
        path_templates: ["/users", "/registracija", "{mount}/registracija"],
        discriminator: "ip",
        host_route: true,
        limit: 200,
        period: 900
      },
      {
        id: "registration.create_by_phone",
        name: "bih/registration-create/phone",
        methods: ["POST"],
        # The per-IP ceiling above is set for a launch venue on one NAT and is
        # relaxed further by the venue safelist, so it says nothing about a
        # script walking real numbers through the form from a handful of
        # addresses: each POST is a paid message aimed at a stranger's phone,
        # and the form answers "already verified" distinctly enough to be an
        # oracle. This budget is keyed on the NUMBER, so neither rotating IPs
        # nor the venue relaxation moves it (review 2026-09-07, lane 2 M1).
        path_templates: ["/users", "/registracija", "{mount}/registracija"],
        discriminator: "phone",
        host_route: true,
        limit: 5,
        period: 900
      },
      {
        id: "reports.corroborate",
        name: "bih/reports.corroborate/ip",
        methods: ["POST"],
        path_regex_template: "\\A{mount}/prijave/[^/]+/potvrdi\\z",
        discriminator: "ip",
        limit: 15,
        period: 60
      },
      {
        id: "reports.create",
        name: "bih/reports.create/ip",
        methods: ["POST"],
        path_template: "{mount}/prijave",
        discriminator: "ip",
        limit: 10,
        period: 60
      },
      {
        id: "sms_authorization.create_by_phone",
        name: "bih/sms-authorization-create/phone",
        methods: ["POST"],
        path_template: "/sms/authorizations",
        discriminator: "phone",
        host_route: true,
        limit: 3,
        period: 900
      },
      {
        id: "sms_authorization.create_by_session",
        name: "bih/sms-authorization-create/session",
        methods: ["POST"],
        path_template: "/sms/authorizations",
        discriminator: "session",
        host_route: true,
        limit: 5,
        period: 900
      },
      {
        # Viber Business Messages carries the bulk of inbound conversation and
        # gets its own budget rather than competing with the guidance-only
        # channels. The host has had this rule since the BM webhook shipped; the
        # registry never declared it, so the contract smoke could not notice its
        # removal (review 2026-09-07, lane 3 F-9).
        id: "viber-bm.webhook",
        name: "bih/viber-bm.webhook/ip",
        methods: ["POST"],
        path_template: "{mount}/viber-bm/webhook",
        discriminator: "ip",
        host_route: true,
        limit: 120,
        period: 60
      },
      {
        id: "viber.webhook",
        name: "bih/viber.webhook/ip",
        methods: ["POST"],
        path_template: "{mount}/viber/webhook",
        discriminator: "ip",
        host_route: true,
        limit: 60,
        period: 60
      }
    ].freeze

    PUBLIC_WRITE_ROUTE_CLASSIFICATIONS = [
      {
        id: "account.public_recognition",
        methods: ["PATCH"],
        path_template: "{mount}/moj-nalog/javno-priznanje",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Low-cost idempotent citizen preference update; CSRF and organization-scoped login required."
      },
      {
        id: "account.update",
        methods: %w(PATCH PUT),
        path_template: "{mount}/moj-nalog",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Delegates to Decidim account update protections; CSRF and organization-scoped login required."
      },
      {
        id: "chat.create",
        methods: ["POST"],
        path_template: "{mount}/chat",
        auth: "anonymous_same_origin",
        throttle_ids: ["chat.create"]
      },
      {
        id: "chat.feedback",
        methods: ["POST"],
        path_template: "{mount}/chat/feedback",
        auth: "anonymous_same_origin",
        throttle_ids: ["chat.feedback"]
      },
      {
        id: "gifts.create",
        methods: ["POST"],
        path_template: "{mount}/podrzi",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Wallet-guarded points transfer with CSRF and organization-scoped login required."
      },
      {
        id: "community_projects.create",
        methods: ["POST"],
        path_template: "{mount}/projekti",
        auth: "authenticated_verified_partner_content_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "community_projects.update",
        methods: ["PATCH"],
        path_template: "{mount}/projekti/prijave/:id",
        auth: "authenticated_verified_partner_content_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_needs.create",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/potrebe",
        auth: "authenticated_verified_partner_volunteer_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_needs.cancel",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/potrebe/:id/otkazi",
        auth: "authenticated_beneficiary_partner_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_offers.create",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/potrebe/:need_id/ponude",
        auth: "authenticated_citizen_or_verified_partner_representative",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_offers.accept",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/ponude/:id/prihvati",
        auth: "authenticated_beneficiary_partner_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_offers.reject",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/ponude/:id/odbij",
        auth: "authenticated_beneficiary_partner_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_offers.deliver",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/ponude/:id/isporuceno",
        auth: "authenticated_offer_owner_or_partner_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_offers.withdraw",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/ponude/:id/povuci",
        auth: "authenticated_offer_owner_or_partner_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "contribution_offers.confirm",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/ponude/:id/potvrdi",
        auth: "authenticated_beneficiary_partner_manager",
        throttle_ids: %w(community_contributions.write_by_ip community_contributions.write_by_session)
      },
      {
        id: "email_confirmation.request",
        methods: ["POST"],
        path_template: "{mount}/potvrdi-email",
        auth: "authenticated_citizen",
        throttle_ids: ["email_confirmation.request_by_session"]
      },
      {
        id: "infobip-chat.webhook",
        methods: ["POST"],
        path_templates: [
          "{mount}/whatsapp/webhook",
          "{mount}/messenger/webhook",
          "{mount}/instagram/webhook"
        ],
        auth: "provider_webhook",
        throttle_ids: ["infobip-chat.webhook"]
      },
      {
        id: "komsiluk.suggest",
        methods: ["POST"],
        path_template: "{mount}/komsiluk/suggest",
        auth: "authenticated_citizen",
        throttle_ids: %w(komsiluk.suggest_by_ip komsiluk.suggest_by_session)
      },
      {
        id: "komsiluk.update",
        methods: ["PATCH"],
        path_template: "{mount}/komsiluk",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Single private assignment update; coordinates are transient and CSRF login gate applies."
      },
      {
        id: "komsiluk_board.close",
        methods: ["PATCH"],
        path_template: "{mount}/komsiluk-board/:id/zatvori",
        auth: "authenticated_verified_komsiluk_member",
        throttle_ids: %w(komsiluk_board.write_by_ip komsiluk_board.write_by_session)
      },
      {
        id: "komsiluk_board.update",
        methods: %w(PATCH PUT),
        path_template: "{mount}/komsiluk-board/:id",
        auth: "authenticated_verified_komsiluk_member",
        throttle_ids: %w(komsiluk_board.write_by_ip komsiluk_board.write_by_session)
      },
      {
        id: "komsiluk_board.resolve",
        methods: ["PATCH"],
        path_template: "{mount}/komsiluk-board/:id/resolve",
        auth: "authenticated_verified_komsiluk_member",
        throttle_ids: %w(komsiluk_board.write_by_ip komsiluk_board.write_by_session)
      },
      {
        id: "komsiluk_board.help",
        methods: ["POST"],
        path_template: "{mount}/komsiluk-board/:id/help",
        auth: "authenticated_verified_komsiluk_member",
        throttle_ids: %w(komsiluk_board.write_by_ip komsiluk_board.write_by_session)
      },
      {
        id: "komsiluk_board.create",
        methods: ["POST"],
        path_template: "{mount}/komsiluk-board",
        auth: "authenticated_verified_komsiluk_member",
        throttle_ids: %w(komsiluk_board.write_by_ip komsiluk_board.write_by_session)
      },
      {
        id: "komsiluk_board.flag",
        methods: ["POST"],
        path_template: "{mount}/komsiluk-board/:id/prijavi",
        auth: "authenticated_verified_komsiluk_member",
        throttle_ids: %w(komsiluk_board.write_by_ip komsiluk_board.write_by_session)
      },
      {
        id: "magic_links.consume",
        methods: ["POST"],
        path_templates: ["/v/:token", "{mount}/v/:token"],
        auth: "anonymous_token",
        throttle_ids: ["magic_links.consume"]
      },
      {
        id: "organizations.add_member",
        methods: ["POST"],
        path_template: "{mount}/organizacija/:id/clanovi",
        auth: "authenticated_partner_manager",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.accept_membership",
        methods: ["PATCH"],
        path_template: "{mount}/organizacija/clanstvo/:membership_id/prihvati",
        auth: "authenticated_invited_citizen",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.update",
        methods: ["PATCH"],
        path_template: "{mount}/organizacije/:id",
        auth: "authenticated_rejected_profile_manager",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.create",
        methods: ["POST"],
        path_template: "{mount}/organizacije",
        auth: "authenticated_citizen",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.decline_membership",
        methods: ["PATCH"],
        path_template: "{mount}/organizacija/clanstvo/:membership_id/odbij",
        auth: "authenticated_invited_citizen",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.leave_membership",
        methods: ["DELETE"],
        path_template: "{mount}/organizacija/clanstvo/:membership_id/napusti",
        auth: "authenticated_partner_member",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.update_member",
        methods: ["PATCH"],
        path_template: "{mount}/organizacija/:id/clanovi/:membership_id",
        auth: "authenticated_partner_manager",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.notice",
        methods: ["POST"],
        path_template: "{mount}/organizacija/:id/obavjestenja",
        auth: "authenticated_partner_content_manager",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.regrant",
        methods: ["POST"],
        path_template: "{mount}/organizacija/:id/regrant",
        auth: "authenticated_partner_manager",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "organizations.spending_request",
        methods: ["POST"],
        path_template: "{mount}/organizacija/:id/potrosnja",
        auth: "authenticated_partner_manager",
        throttle_ids: %w(organizations.write_by_ip organizations.write_by_session)
      },
      {
        id: "phone_sessions.create",
        methods: ["POST"],
        path_template: "{mount}/prijava",
        auth: "anonymous",
        throttle_ids: %w(phone_login.request_by_ip phone_login.request_by_phone)
      },
      {
        id: "phone_sessions.verify_code",
        methods: ["POST"],
        path_template: "{mount}/prijava/kod",
        auth: "anonymous_session_challenge",
        throttle_ids: ["phone_login.code_by_ip"]
      },
      {
        id: "phone_verification.change",
        methods: ["DELETE"],
        path_template: "{mount}/verifikacija/telefon",
        auth: "authenticated_citizen",
        throttle_ids: ["phone_verification.change_by_session"]
      },
      {
        id: "phone_verification.code",
        methods: ["POST"],
        path_template: "{mount}/verifikacija/telefon/kod",
        auth: "authenticated_citizen",
        throttle_ids: ["phone_verification.code_by_session"]
      },
      {
        id: "phone_verification.resend",
        methods: ["POST"],
        path_template: "{mount}/verifikacija/telefon/ponovo",
        auth: "authenticated_citizen",
        throttle_ids: ["phone_verification.resend_by_session"]
      },
      # The one-step registration's pending page (spec 5.4). Nobody is signed
      # in on any of these: the citizen is gated by a Registration::PendingAccess
      # token in their own session, which is what "anonymous_pending_registration_token"
      # names. Each shares the signed-in verification page's per-session budget.
      {
        id: "registration.change",
        methods: ["DELETE"],
        path_templates: ["/registracija/potvrda", "{mount}/registracija/potvrda"],
        auth: "anonymous_pending_registration_token",
        throttle_ids: ["phone_verification.change_by_session"]
      },
      {
        id: "registration.code",
        methods: ["POST"],
        path_templates: ["/registracija/potvrda/kod", "{mount}/registracija/potvrda/kod"],
        auth: "anonymous_pending_registration_token",
        throttle_ids: ["phone_verification.code_by_session"]
      },
      {
        id: "registration.create",
        methods: ["POST"],
        path_templates: ["/users", "/registracija", "{mount}/registracija"],
        auth: "anonymous",
        throttle_ids: %w(registration.create registration.create_by_phone)
      },
      {
        id: "registration.resend",
        methods: ["POST"],
        path_templates: ["/registracija/potvrda/ponovo", "{mount}/registracija/potvrda/ponovo"],
        auth: "anonymous_pending_registration_token",
        throttle_ids: ["phone_verification.resend_by_session"]
      },
      {
        # Destroys a never-verified pending account, so that the citizen who
        # mistyped the number and lost the browser they registered in can
        # register again with the same address.
        id: "registration.start_over",
        methods: ["POST"],
        path_templates: [
          "/registracija/potvrda/pocni-ispocetka",
          "{mount}/registracija/potvrda/pocni-ispocetka"
        ],
        auth: "anonymous_pending_registration_token",
        throttle_ids: ["phone_verification.change_by_session"]
      },
      {
        # A POST, and a write route, because it can sign the waiting browser
        # in: the poll is where the desktop hand-off happens (R-D2/R-D4).
        id: "registration.status",
        methods: ["POST"],
        path_templates: ["/registracija/potvrda/status", "{mount}/registracija/potvrda/status"],
        auth: "anonymous_pending_registration_token",
        throttle_ids: ["phone_verification.status_by_session"]
      },
      {
        id: "reports.corroborate",
        methods: ["POST"],
        path_template: "{mount}/prijave/:reference/potvrdi",
        auth: "anonymous",
        throttle_ids: ["reports.corroborate"]
      },
      {
        id: "reports.create",
        methods: ["POST"],
        path_template: "{mount}/prijave",
        auth: "anonymous",
        throttle_ids: ["reports.create"]
      },
      {
        id: "rewards.cancel",
        methods: ["POST"],
        path_template: "{mount}/nagrade/zahtjevi/:id/otkazi",
        auth: "authenticated_fulfillment_owner",
        throttle_ids: [],
        no_throttle_reason: "Owner-only row-locked cancellation with append-only ledger reversal, terminal-state guard and CSRF protection."
      },
      {
        id: "rewards.redeem",
        methods: ["POST"],
        path_template: "{mount}/nagrade/redeem/:reward_key",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Explicitly confirmed redemption with request idempotency, stock and wallet advisory locks, balance guard and CSRF login checks."
      },
      {
        id: "sms_authorization.create",
        methods: ["POST"],
        path_template: "/sms/authorizations",
        auth: "authenticated_citizen",
        throttle_ids: %w(sms_authorization.create_by_phone sms_authorization.create_by_session)
      },
      {
        id: "viber.webhook",
        methods: ["POST"],
        path_template: "{mount}/viber/webhook",
        auth: "provider_webhook",
        throttle_ids: ["viber.webhook"]
      },
      {
        id: "viber-bm.webhook",
        methods: ["POST"],
        path_template: "{mount}/viber-bm/webhook",
        auth: "provider_webhook",
        throttle_ids: ["viber-bm.webhook"]
      },
      {
        id: "volunteer.availability",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/dostupnost",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Private profile update bounded by model limits; CSRF and organization-scoped login required."
      },
      {
        id: "volunteer.cancel_signup",
        methods: ["DELETE"],
        path_template: "{mount}/volontiranje/prijavi-se/:opportunity_id",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Single RSVP state transition with row lock, CSRF and organization-scoped login required."
      },
      {
        id: "volunteer.hours",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/sati",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Pending hour log is review-gated and attendance-gated; CSRF login gate applies."
      },
      {
        id: "volunteer.opportunity",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/prilika",
        auth: "authenticated_partner_member",
        throttle_ids: [],
        no_throttle_reason: "Moderated opportunity proposal with bounded recurring series and partner-membership gate."
      },
      {
        id: "volunteer.signup",
        methods: ["POST"],
        path_template: "{mount}/volontiranje/prijavi-se/:opportunity_id",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "RSVP state transition is capacity-locked and CSRF login gated."
      },
      {
        id: "platform_delivery.acknowledge",
        methods: ["POST"],
        path_template: "{mount}/platform-receipt",
        auth: "expiring_signed_delivery_capability",
        throttle_ids: [],
        no_throttle_reason: "An at-most-2048-byte expiring signed capability identifies one tenant-scoped receipt; " \
                            "row-locked replay is idempotent, cannot send messages or create rows, and stores no caller payload."
      },
      {
        id: "web_push.test",
        methods: ["POST"],
        path_template: "{mount}/push-notification-test",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Controller enforces an atomic Redis one-minute per-user cooldown, current-device ownership, organization scope and CSRF."
      },
      {
        id: "web_push.unsubscribe",
        methods: ["DELETE"],
        path_template: "{mount}/push-subscription",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Idempotent removal from the signed-in user's own subscriptions under a row lock, organization scope and CSRF."
      },
      {
        id: "welcome.start",
        methods: ["POST"],
        path_template: "{mount}/dobrodosli",
        auth: "authenticated_citizen",
        throttle_ids: [],
        no_throttle_reason: "Idempotent one-flag write on the signed-in citizen's own account; CSRF and " \
                            "organization-scoped login required, and a repeat is a no-op."
      }
    ].sort_by { |route| route.fetch(:id) }.freeze

    def self.required_public_assets
      REQUIRED_PUBLIC_ASSETS
    end

    def self.required_public_asset_manifest
      required_public_assets.map { |path| { public_path: path, relative_path: path.delete_prefix("/") } }
    end

    def self.public_asset_source_root
      File.expand_path("../../public", __dir__)
    end

    def self.required_public_asset_source_path(relative_path, source_root: public_asset_source_root)
      File.join(File.expand_path(source_root), relative_path.to_s.delete_prefix("/"))
    end

    def self.required_public_asset_source_manifest(source_root: public_asset_source_root)
      required_public_asset_manifest.map do |asset|
        relative_path = asset.fetch(:relative_path)
        source_path = required_public_asset_source_path(relative_path, source_root:)
        asset.merge(
          source_path:,
          source_exists: File.file?(source_path),
          source_size_bytes: File.file?(source_path) ? File.size(source_path) : nil
        )
      end
    end

    def self.install_public_assets!(public_root:, source_root: public_asset_source_root, overwrite: false)
      root = public_root.to_s.strip
      raise ArgumentError, "public_root is required" if root.empty?

      manifest = required_public_asset_source_manifest(source_root:)
      missing = manifest.reject { |asset| asset.fetch(:source_exists) }
      if missing.any?
        missing_paths = missing.map { |asset| asset.fetch(:relative_path) }.join(", ")
        raise "Missing packaged public assets: #{missing_paths}"
      end

      copied = []
      skipped = []
      manifest.each do |asset|
        relative_path = asset.fetch(:relative_path)
        destination_path = File.join(root, relative_path)
        if File.exist?(destination_path) && !overwrite
          skipped << relative_path
          next
        end

        FileUtils.mkdir_p(File.dirname(destination_path))
        FileUtils.cp(asset.fetch(:source_path), destination_path)
        copied << relative_path
      end

      { copied:, skipped:, public_root: root, source_root: File.expand_path(source_root) }
    end

    def self.install_required_public_assets!(public_root:, source_root: public_asset_source_root, overwrite: false)
      install_public_assets!(public_root:, source_root:, overwrite:)
    end

    def self.required_public_surfaces_for_mount(mount_path: public_mount_path)
      mount_config = public_throttle_mount_config(mount_path, true)
      PUBLIC_SURFACE_REVIEW_ITEMS.map { |surface| expand_public_surface_contract(surface, mount_config[:path_mount]) }
    end

    def self.required_public_surface_manifest(mount_path: public_mount_path)
      required_public_surfaces_for_mount(mount_path:)
    end

    def self.required_brand_asset_reviews
      BRAND_ASSET_REVIEW_FAMILIES
    end

    def self.required_decidim_modules
      REQUIRED_DECIDIM_MODULES
    end

    def self.required_privacy_event_contracts(mount_path: public_mount_path)
      Decidim::Bih::PrivacyAuditContracts.audit_event_streams(public_mount_path: mount_path)
    end

    def self.required_privacy_retention_buckets
      Decidim::Bih::PrivacyAuditContracts.retention_buckets
    end

    def self.required_audit_event_streams(mount_path: public_mount_path)
      Decidim::Bih::PrivacyAuditContracts.audit_event_streams(public_mount_path: mount_path)
    end

    def self.privacy_audit_contract_manifest(mount_path: public_mount_path)
      Decidim::Bih::PrivacyAuditContracts.manifest(public_mount_path: mount_path)
    end

    def self.expand_public_surface_contract(surface, mount)
      expanded = {
        owner: "engine",
        lifecycle: "canonical",
        branding_review_required: true,
        stable_compatibility_path: true
      }.merge(surface)
      expanded[:public_nav] = !expanded[:menu_i18n_key].nil? unless expanded.has_key?(:public_nav)

      templates = Array(surface[:path_templates] || surface[:path_template])
      expanded[:paths] = expand_public_surface_templates(templates, mount) if templates.any?
      expanded
    end

    def self.expand_public_surface_templates(templates, mount)
      expand_public_throttle_templates(templates, mount).map { |path| path.empty? ? "/" : path }
    end

    def self.required_public_throttles
      REQUIRED_PUBLIC_THROTTLES
    end

    def self.required_public_write_routes
      PUBLIC_WRITE_ROUTE_CLASSIFICATIONS
    end

    def self.required_public_write_routes_for_mount(mount_path: public_mount_path)
      mount_config = public_throttle_mount_config(mount_path, true)
      required_public_write_routes.map do |route|
        expanded = route.dup
        templates = Array(route[:path_templates] || route[:path_template])
        expanded[:paths] = expand_public_throttle_templates(templates, mount_config[:path_mount]) if templates.any?
        expanded
      end
    end

    def self.required_public_throttles_for_mount(mount_path: public_mount_path, short_magic_links: magic_link_short_path_enabled)
      mount_config = public_throttle_mount_config(mount_path, short_magic_links)
      required_public_throttles.map { |contract| expand_public_throttle_contract(contract, mount_config) }
    end

    def self.public_throttle_mount_config(mount_path, short_magic_links)
      mount = normalize_public_mount_path(mount_path)
      {
        path_mount: mount == "/" ? "" : mount,
        regex_mount: mount == "/" ? "" : Regexp.escape(mount),
        include_short_magic_links: truthy_config_value?(short_magic_links)
      }
    end

    def self.expand_public_throttle_contract(contract, mount_config)
      expanded = contract.dup
      templates = public_throttle_path_templates(contract, mount_config[:include_short_magic_links])
      regex_templates = Array(contract[:path_regex_templates] || contract[:path_regex_template])
      expanded[:paths] = expand_public_throttle_templates(templates, mount_config[:path_mount]) if templates.any?
      expanded[:path_regexes] = expand_public_throttle_templates(regex_templates, mount_config[:regex_mount]) if regex_templates.any?
      expanded
    end

    def self.public_throttle_path_templates(contract, include_short_magic_links)
      templates = Array(contract[:path_templates] || contract[:path_template])
      return templates unless contract[:id] == "magic_links.consume" && !include_short_magic_links

      templates.reject { |template| template == "/v/:token" }
    end

    def self.expand_public_throttle_templates(templates, mount)
      templates.map { |template| template.gsub("{mount}", mount) }
    end

    def self.host_contract_manifest(mount_path: public_mount_path, short_magic_links: magic_link_short_path_enabled)
      mount = normalize_public_mount_path(mount_path)
      include_short_magic_links = truthy_config_value?(short_magic_links)

      {
        public_mount_path: mount,
        magic_link_short_path_enabled: include_short_magic_links,
        required_public_assets: required_public_asset_manifest,
        required_public_throttles: required_public_throttles_for_mount(
          mount_path: mount,
          short_magic_links: include_short_magic_links
        ),
        required_public_write_routes: required_public_write_routes_for_mount(mount_path: mount),
        required_public_surfaces: required_public_surfaces_for_mount(mount_path: mount),
        required_brand_asset_reviews:,
        required_decidim_modules:,
        privacy_audit_contract: privacy_audit_contract_manifest(mount_path: mount),
        required_provider_contracts:
      }
    end

    def self.required_provider_contracts
      Decidim::Bih::ProviderContracts.manifest
    end

    def self.truthy_config_value?(value)
      return value if value == true || value == false

      !value.to_s.match?(/\A(false|0|no)\z/i)
    end

    def self.normalize_public_mount_path(path)
      raw = path.to_s.strip
      raw = "/biceriseno" if raw.empty?
      raw = "/#{raw}" unless raw.start_with?("/")
      return "/" if raw == "/"

      raw.delete_suffix("/")
    end

    def self.normalized_public_mount_path
      normalize_public_mount_path(public_mount_path)
    end

    def self.public_path(path = nil)
      base = normalized_public_mount_path
      suffix = path.to_s.strip
      return base if suffix.empty? || suffix == "/"

      suffix = "/#{suffix}" unless suffix.start_with?("/")
      base == "/" ? suffix : "#{base}#{suffix}"
    end

    def self.public_url(path = nil, base_url:)
      return public_path(path) if base_url.to_s.strip.empty?

      "#{base_url.to_s.chomp("/")}#{public_path(path)}"
    end

    def self.magic_link_path(raw_token, short: magic_link_short_path_enabled)
      token = raw_token.to_s
      raise ArgumentError, "raw_token is required" if token.empty?

      short ? "/v/#{token}" : public_path("v/#{token}")
    end

    def self.magic_link_url(raw_token, host:, scheme: "https", short: magic_link_short_path_enabled)
      "#{base_url_for(host, scheme:)}#{magic_link_path(raw_token, short:)}"
    end

    # The short invite path for one referral code, or nil when the host has
    # not configured one. Slashes on the setting are normalised so "/p", "p"
    # and "p/" all give "/p/<code>"; the code is escaped as a path segment.
    def self.invite_short_path_for(code)
      base = invite_short_path.to_s.strip.gsub(%r{\A/+|/+\z}, "")
      return nil if base.empty? || code.to_s.empty?

      "/#{base}/#{ERB::Util.url_encode(code.to_s)}"
    end

    # The community hub tab that holds the invite link, the QR and the share
    # buttons. Six surfaces send a citizen here — the desktop header pill, the
    # top nudge, the leaderboard CTA, the mobile "Još" sheet, the account
    # checklist and the referral bell — and they read this one method rather
    # than each spelling the tab out, so the hub can be remounted or the tab
    # renamed in a single place. It follows #public_path, so a host that mounts
    # the engine elsewhere moves every invite entry point with it.
    #
    # There is deliberately no absolute-URL sibling: every caller is rendering
    # into a page on this host, and an unused #invite_url would be one more
    # thing to keep correct for nobody.
    INVITE_TAB = "pozovi"

    def self.invite_path
      "#{public_path("zajednistvo")}?tab=#{INVITE_TAB}"
    end

    # The one-step registration lives at ONE base per host and every URL in the
    # flow is built from it: a host that sets registration_base_path
    # ("/registracija") serves it at that root path and owns the URL; one that
    # leaves it nil is served from under the engine mount. A citizen who
    # arrived at the short path must not be walked under the mount halfway
    # through, and a mailed link must land where the pages themselves live —
    # which is why the mailer, the controller's own helpers and the throttle
    # contract all read the same rule from here.
    #
    # +suffix+ is the step below that base ("potvrda", or
    # "potvrda?pending_token=…").
    def self.registration_path_for(suffix = nil)
      tail = suffix.to_s.strip
      tail = "/#{tail}" unless tail.empty? || tail.start_with?("/", "?")

      base = registration_base_path.to_s.strip
      return public_path("registracija#{tail}") if base.empty?

      base = "/#{base}" unless base.start_with?("/")
      # Every trailing slash, not just the last one: "//" is the same degenerate
      # root typed twice, and a single chomp would leave "/" behind and build
      # "//potvrda" — a protocol-relative URL, not a path on this host.
      base = base.sub(%r{/+\z}, "")
      # A base of "/" is the degenerate one: the registration IS the site root,
      # and trimming its slashes leaves nothing. Nothing is not a path — the
      # pending page would render an empty href and the resume e-mail a bare
      # origin — so the root answers for itself here, exactly as #public_path
      # guards its own root mount.
      return "/#{tail.delete_prefix("/")}" if base.empty?

      "#{base}#{tail}"
    end

    # #registration_path_for as an absolute URL. There is no request behind a
    # mailer, so the host is passed in — either a bare host or a full base URL,
    # the same shape #magic_link_url accepts.
    def self.registration_url(suffix = nil, host:, scheme: "https")
      "#{base_url_for(host, scheme:)}#{registration_path_for(suffix)}"
    end

    # A bare host ("example.test") becomes an absolute base URL; a value that
    # already carries a scheme is taken as the base URL itself.
    def self.base_url_for(host, scheme: "https")
      host_or_base_url = host.to_s.strip.chomp("/")
      raise ArgumentError, "host is required" if host_or_base_url.empty?

      return host_or_base_url if host_or_base_url.match?(%r{\Ahttps?://}i)

      "#{scheme}://#{host_or_base_url}"
    end
    private_class_method :base_url_for

    def self.organization_scoped_user(user, organization)
      return nil unless user && organization
      return user if user.respond_to?(:organization) && user.organization == organization
      return user if user.respond_to?(:decidim_organization_id) && user.decidim_organization_id == organization.id

      nil
    end
  end
end
