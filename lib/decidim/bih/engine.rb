# frozen_string_literal: true

require "rails"
require "decidim/core"
require "decidim/bih/mail_hooks"
require "decidim/bih/private_blob_routes"
require "decidim/bih/worker_shutdown"

module Decidim
  module Bih
    # Rails engine that wires the Bosnian-market customizations into a host
    # Decidim application: shared locales, view/asset overrides and
    # initializers live here.
    class Engine < ::Rails::Engine
      isolate_namespace Decidim::Bih

      initializer "decidim_bih.ransack_resource_bounds" do
        require "decidim/bih/ransack_resource_bounds"
        Decidim::Bih::RansackResourceBounds.install!
      end

      initializer "decidim_bih.rack_proxy_response_guard" do
        require "decidim/bih/rack_proxy_response_guard"
        Decidim::Bih::RackProxyResponseGuard.install!
      end

      # Make this engine's locale files available to the host app and let them
      # override Decidim core translations (loaded last).
      initializer "decidim_bih.locales", before: :add_locales do |app|
        app.config.i18n.load_path += Dir[root.join("config", "locales", "**", "*.{rb,yml}")]
      end

      # Expose this engine's migrations to the host app so `rails db:migrate`
      # in the application picks up the engine-owned tables. Guard against the
      # engine appending its own path to itself when mounted in-place.
      initializer "decidim_bih.migrations" do |app|
        next if app.root.to_s.start_with?(root.to_s)

        config.paths["db/migrate"].expanded.each do |expanded_path|
          app.config.paths["db/migrate"] << expanded_path
        end
      end

      # Sidekiq fires :quiet on TSTP and at the start of a TERM shutdown. Long
      # jobs stop starting provider calls from then on (see WorkerShutdown and
      # docs in Ai::CaseAgent); in-flight calls still get the :timeout: window.
      initializer "decidim_bih.worker_shutdown" do
        next unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)

        ::Sidekiq.configure_server { |config| Decidim::Bih::WorkerShutdown.install!(config) }
      end

      # Isti obrazac kao decidim_core.param_filtering: jednokratni ulazni kod
      # pozivnice se šalje POST tijelom (nikad kroz URL), pa mora biti
      # filtriran iz request logova bez obzira koji host učita ovaj engine —
      # oslanjanje samo na host app-ov initializer ne pokriva generisani
      # test-host niti drugu instalaciju ovog engine-a.
      initializer "decidim_bih.param_filtering" do |app|
        # :verification_code i :otp_code su jednokratne šifre iz SMS-a/Vibera —
        # putuju POST tijelom skrivenog "unesi kod" polja i Decidimove
        # /sms/authorizations forme, pa moraju biti filtrirani jednako kao
        # ulazni kod pozivnice.
        # :phone je polje forme za ponovnu potvrdu broja, a :mobile_phone
        # Decidimove /sms/authorizations forme
        # (mobile_phone[mobile_phone_number]) — broj građanina ne smije
        # završiti u request logu ni kod drugog hosta koji učita ovaj engine.
        # :pending_token je pristup stranici potvrde registracije koji stiže
        # e-mailom (?pending_token=…) — potpisani id koji otvara tu stranicu,
        # pa nema šta da traži u request logu.
        app.config.filter_parameters += [
          :batch_items, :decision, :preview_token, :proposal_ciphertext, :review_draft, :reconciliation_evidence, :entry_code, :verification_code, :otp_code,
          :phone, :mobile_phone, :pending_token,
          /\Aauth\z/, :p256dh, :endpoint, :subscriptions, :notification_settings
        ]
      end

      # Request logovi i SQL logovi filtriraju se iz DVIJE različite liste.
      # config.filter_parameters pokriva parametre zahtjeva; #inspect i
      # debug-level bind parametri čitaju ActiveRecord::Base.filter_attributes,
      # a Rails te dvije liste ne drži u koraku (railtie
      # active_record.set_filter_attributes snima filter_parameters prije nego
      # što initializeri engine-a i hosta dodaju svoje). Bez ovoga broj
      # građanina je filtriran iz request loga i ispisan u cijelosti čim
      # operater podigne log level na debug — tačno kad neko rješava incident i
      # najmanje misli na PII.
      #
      # Postavlja se na Base, pa se kroz class_attribute prenosi na svaki model
      # koji nije postavio svoju listu (CitizenPhoneRecord i RewardFulfillment
      # jesu i ostaju netaknuti). Unija, ne dodjela: host koji je već postavio
      # svoju listu ne smije je izgubiti time što je učitao ovaj engine.
      config.after_initialize do |app|
        ActiveRecord::Base.filter_attributes |= Array(app.config.filter_parameters)
      end

      config.to_prepare do
        ActiveStorage::SetBlob.prepend(Decidim::Bih::PrivateBlobRoutes) unless ActiveStorage::SetBlob < Decidim::Bih::PrivateBlobRoutes
      end

      # Correlate outbound mail to the shared communication history.
      #
      # Both hooks are needed and they are not interchangeable: the INTERCEPTOR
      # runs before the SMTP conversation (so a leg is claimed before the
      # irreversible hand-off, and the internal correlation header is removed
      # before the message leaves the building), the OBSERVER runs after the
      # delivery method returned (so `accepted` means SMTP took it — never
      # inbox placement and never reading).
      #
      # `on_load(:action_mailer)` rather than a bare reference: ActionMailer is
      # lazily loaded, and touching ActionMailer::Base at boot would force it.
      # The registered object is `MailHooks`, which lives in lib/ precisely so
      # this line does not have to name an autoloaded constant before the
      # autoloaders exist — see the comment in that file.
      initializer "decidim_bih.mail_recorder" do
        ActiveSupport.on_load(:action_mailer) { Decidim::Bih::MailHooks.install! }
      end

      # app/ mailer constants are available only after autoloaders are ready.
      # Run again on development reload without duplicate prepends.
      initializer "decidim_bih.core_mail_reply_defaults" do |app|
        app.config.to_prepare do
          extension = Decidim::Bih::MailReplyTo::CoreSmtpDefaults
          mailer = Decidim::ApplicationMailer
          mailer.prepend(extension) unless mailer < extension
        end
      end

      # Make this engine's cells discoverable. Decidim renders content blocks
      # through the Cells gem, which resolves templates via its own
      # Cell::ViewModel.view_paths — engine app/cells dirs must be added
      # explicitly (Rails' view_paths alone is not consulted by Cells).
      #
      # We insert this engine's path BEFORE core's (but after the host app's own
      # app/cells) so that when this engine ships a template at the same path as
      # a core cell — e.g. the global menu content block
      # (decidim/content_blocks/global_menu/show.erb) — the engine copy is
      # resolved first and overrides core, instead of merely adding new cells.
      # Cells resolves by returning the first existing prefix; core registers its
      # absolute app/cells path before this engine's initializer (we run after
      # it), and the host app's app/cells is registered first by cells-rails so
      # app-level overrides still win over the engine.
      initializer "decidim_bih.cells", after: "decidim_core.add_cells_view_paths" do
        paths = Cell::ViewModel.view_paths
        cells_path = root.join("app", "cells").to_s
        # cells-rails stores Pathname entries, core/this engine store Strings —
        # normalize on to_s for comparisons so insertion is order-correct.
        paths.reject! { |p| p.to_s == cells_path }
        app_cells_path = Rails.root.join("app/cells").to_s
        insert_at = paths.index { |p| p.to_s == app_cells_path }
        if insert_at
          paths.insert(insert_at + 1, cells_path)
        else
          paths.unshift(cells_path)
        end
      end

      # Register the branded homepage content blocks: the poster "MI hero"
      # (poster stack + live ticker + stats strip), the "MI hub" (the
      # "MI <verb>" module tiles + omnichannel chatbot band) and the closing
      # "MI CTA". Data-light: copy comes from i18n, styling from the host
      # theme. Placement on the homepage is set via the organization's
      # content-block layout (admin / production runner).
      initializer "decidim_bih.content_blocks" do
        # NOTE: the RemixIcons these cells use are registered in #after_initialize
        # (see MI_ICONS below) so the "already registered" guard runs AFTER core
        # and decidim_awesome have registered their own icons.
        # Existing homepage layouts retain their global_menu block on0.32.
        Decidim.content_blocks.register(:homepage, :global_menu) do |content_block|
          content_block.cell = "decidim/content_blocks/global_menu"
          content_block.public_name_key = "decidim.content_blocks.global_menu.name"
          content_block.default!
        end

        Decidim.content_blocks.register(:homepage, :mi_hero) do |content_block|
          content_block.cell = "decidim/bih/content_blocks/mi_hero"
          content_block.public_name_key = "decidim.bih.content_blocks.mi_hero.name"
        end

        Decidim.content_blocks.register(:homepage, :mi_hub) do |content_block|
          content_block.cell = "decidim/bih/content_blocks/mi_hub"
          content_block.public_name_key = "decidim.bih.content_blocks.mi_hub.name"
        end

        Decidim.content_blocks.register(:homepage, :mi_cta) do |content_block|
          content_block.cell = "decidim/bih/content_blocks/mi_cta"
          content_block.public_name_key = "decidim.bih.content_blocks.mi_cta.name"
        end
      end

      # Public navigation for the engine's citizen surfaces. This is generic
      # Bosnian-market nav machinery (engine routes + engine i18n keys), so it
      # belongs here, mirroring how the admin menu is registered in AdminEngine.
      # The blocks run at render time in the host's view context, where the
      # mounted `decidim_bih` route helper resolves regardless of mount path.
      PUBLIC_MENU_ITEMS = [
        { id: :bih_onboarding, key: "decidim.bih.menu.onboarding", route: :onboarding_guide_path, position: 1.0 },
        { id: :bih_reports, key: "decidim.bih.menu.reports", route: :new_report_path, position: 1.1 },
        { id: :bih_reports_map, key: "decidim.bih.menu.reports_map", route: :reports_map_path, position: 1.2 },
        { id: :bih_reports_tracker, key: "decidim.bih.menu.reports_tracker", route: :reports_path, position: 1.3 },
        { id: :bih_donations, key: "decidim.bih.menu.donations", route: :community_projects_path, position: 3 },
        { id: :bih_impact, key: "decidim.bih.menu.impact", route: :impact_path, position: 3.5 },
        { id: :bih_mi_bot, key: "decidim.bih.menu.mi_bot", route: :mi_bot_path, position: 4 },
        { id: :bih_community_hub, key: "decidim.bih.menu.community_hub", route: :community_hub_path, position: 5 },
        { id: :bih_volunteer, key: "decidim.bih.menu.volunteer", route: :volunteer_path, position: 6 },
        { id: :bih_komsiluk_board, key: "decidim.bih.menu.komsiluk_board", route: :komsiluk_board_index_path, position: 7 }
      ].freeze

      PRIMARY_PUBLIC_MENU_ITEMS = [
        { id: :bih_reports, key: "decidim.bih.menu.reports", route: :new_report_path, position: 1.1 },
        { id: :bih_decide, key: "decidim.bih.menu.decide", path: "/processes", position: 1.2 },
        { id: :bih_volunteer, key: "decidim.bih.menu.volunteer_action", route: :volunteer_path, position: 1.3 },
        { id: :bih_donations, key: "decidim.bih.menu.donate_action", route: :community_projects_path, position: 1.4 },
        { id: :bih_community_hub, key: "decidim.bih.menu.community", route: :community_hub_path, position: 1.5 },
        { id: :bih_komsiluk, key: "decidim.bih.menu.komsiluk_short", route: :komsiluk_board_index_path, position: 1.6 },
        { id: :bih_impact, key: "decidim.bih.menu.impact_public", route: :impact_path, position: 1.7 }
      ].freeze

      HOME_PUBLIC_MENU_ITEMS = [
        { id: :bih_onboarding, key: "decidim.bih.menu.onboarding_short", route: :onboarding_guide_path, position: 1.0 },
        { id: :bih_reports, key: "decidim.bih.menu.reports", route: :new_report_path, position: 2.0 },
        { id: :bih_volunteer, key: "decidim.bih.menu.volunteer_action", route: :volunteer_path, position: 3.0 },
        { id: :bih_donations, key: "decidim.bih.menu.donate_action", route: :community_projects_path, position: 4.0 },
        { id: :bih_decide, key: "decidim.bih.menu.decide", path: "/processes", position: 5.0 },
        { id: :bih_mi_bot, key: "decidim.bih.menu.mi_bot_short", route: :mi_bot_path, position: 6.0 },
        { id: :bih_community_hub, key: "decidim.bih.menu.community", route: :community_hub_path, position: 7.0 },
        { id: :bih_komsiluk, key: "decidim.bih.menu.komsiluk", route: :komsiluk_board_index_path, position: 8.0 }
      ].freeze

      initializer "decidim_bih.menus" do
        [:menu, :mobile_menu].each do |menu_name|
          Decidim.menu menu_name do |menu|
            PRIMARY_PUBLIC_MENU_ITEMS.each do |item|
              url = item[:route] ? decidim_bih.public_send(item[:route]) : item.fetch(:path)
              menu.add_item item[:id],
                            I18n.t(item[:key]),
                            url,
                            position: item[:position],
                            active: :inclusive
            end
          end
        end

        Decidim.menu :home_content_block_menu do |menu|
          HOME_PUBLIC_MENU_ITEMS.each do |item|
            url = item[:route] ? decidim_bih.public_send(item[:route]) : item.fetch(:path)
            menu.add_item item[:id],
                          I18n.t(item[:key]),
                          url,
                          position: item[:position],
                          active: :inclusive
          end
        end

        [:menu, :mobile_menu, :home_content_block_menu].each do |menu_name|
          Decidim.menu menu_name do |menu|
            menu.remove_item :participatory_processes
          end
        end

        # Wallet + Komšiluk board → the logged-in user/account menu (private;
        # never in the public nav).
        Decidim.menu :user_menu do |menu|
          # One communication page, everywhere. Core's item points at
          # /notifications_settings, whose GET now redirects here anyway;
          # leaving it would send citizens through a redirect and would make
          # the canonical page link back into it.
          menu.remove_item :notifications_settings

          menu.add_item :bih_communication_settings,
                        I18n.t("decidim.bih.communication_settings.title"),
                        decidim_bih.account_notification_settings_path,
                        position: 1.1,
                        active: :inclusive

          menu.add_item :bih_account_overview,
                        I18n.t("decidim.bih.menu.account_overview"),
                        decidim_bih.account_overview_path,
                        position: 1.25,
                        active: :inclusive

          menu.add_item :bih_wallet,
                        I18n.t("decidim.bih.menu.wallet"),
                        decidim_bih.wallet_path,
                        position: 1.3,
                        active: :inclusive

          menu.add_item :bih_komsiluk,
                        I18n.t("decidim.bih.menu.komsiluk"),
                        decidim_bih.komsiluk_board_index_path,
                        position: 1.4,
                        active: :inclusive

          organization = respond_to?(:current_organization, true) ? current_organization : nil
          user = Decidim::Bih.organization_scoped_user(current_user, organization) if organization && respond_to?(:current_user, true)

          if user && organization && Decidim::Bih::PartnerMembership.table_exists? && Decidim::Bih::PartnerProfile.table_exists?
            menu.add_item :bih_organizations,
                          I18n.t("decidim.bih.menu.my_organizations"),
                          decidim_bih.organizations_path,
                          position: 1.45,
                          active: :inclusive

            memberships = Decidim::Bih::PartnerMembership
                          .for_user(user, organization:)
                          .joins(:partner_profile)
                          .includes(:partner_profile)
                          .order("decidim_bih_partner_profiles.display_name")
                          .to_a

            memberships.select { |membership| membership.partner_profile&.verified? }.each_with_index do |membership, index|
              profile = membership.partner_profile
              menu.add_item :"bih_organization_#{profile.id}",
                            I18n.t("decidim.bih.menu.organization_profile", name: profile.display_name),
                            decidim_bih.organization_path(profile.slug),
                            position: 1.46 + (index * 0.01),
                            active: :inclusive
            end
          end
        end
      end

      # This engine's view/class overrides live in app/overrides with
      # *_override.rb filenames that do NOT map to Zeitwerk constant paths, so the
      # directory must be ignored by the autoloader (otherwise production eager
      # load raises a NameError). The files are loaded in to_prepare — late enough
      # that core constants (e.g. Decidim::ProfileCell) exist — and re-run on each
      # code reload in development.
      overrides_path = "#{root}/app/overrides"
      initializer "decidim_bih.overrides_autoload_ignore" do
        Rails.autoloaders.main.ignore(overrides_path) if Rails.respond_to?(:autoloaders)
      end

      config.to_prepare do
        Decidim::Authorization.include Decidim::Bih::Race::QualificationTracking unless Decidim::Authorization < Decidim::Bih::Race::QualificationTracking
        Dir.glob("#{Decidim::Bih::Engine.root}/app/overrides/**/*_override.rb").sort.each do |override| # rubocop:disable Lint/RedundantDirGlobSort
          load override
        end
      end

      initializer "decidim_bih.postal_admin_routes", after: :load_config_initializers do
        Decidim::Verifications::PostalLetter::AdminEngine.routes.append do
          resources :pending_authorizations, only: [] do
            post "postages/resend", to: "postages#resend", as: :resend_postage
            delete "postages/cancel", to: "postages#cancel", as: :cancel_postage
          end
        end
      end

      # RemixIcons the MI cells / goodwill surfaces render that core does not ship
      # pre-registered (Decidim 0.31 only renders icons present in the registry).
      # Registered in #after_initialize so the has_key? guard sees the icons core
      # and decidim_awesome register in THEIR initializers — otherwise registering
      # a name they also own fires a "already registered" deprecation.
      MI_ICONS = [
        ["heart-line", "Heart"],
        ["lightbulb-line", "Lightbulb"],
        ["chat-3-line", "Chat"],
        ["megaphone-line", "Megaphone"],
        ["shield-check-line", "Shield check"],
        ["copper-coin-line", "Coin"],
        ["vip-crown-line", "Crown"],
        ["checkbox-circle-line", "Verified"],
        ["gift-line", "Gift"],
        # The postal-verification queue's two print actions. Core does not
        # register it, and Decidim::IconRegistry raises at RENDER time on an
        # unregistered name — the operator would get a 500, not a missing glyph.
        ["printer-line", "Print postal letter"],
        # Round 25 (W4.6) — admin sidebar entries for the operator surfaces.
        ["file-list-3-line", "Report list"],
        ["user-search-line", "Citizen lookup"],
        ["flag-line", "Moderation"],
        ["pulse-line", "Integrations health"],
        # Round 25 / Wave 6 — operator configuration surfaces.
        ["settings-3-line", "Goodwill settings"],
        ["map-pin-line", "Local areas"],
        ["mail-send-line", "Sistem 48 routing"],
        ["close-circle-line", "Close circle"],
        # Public guide capability index.
        ["add-circle-line", "Add"],
        ["search-line", "Search"],
        ["map-2-line", "Map"],
        ["pie-chart-2-line", "Problem heatmap"],
        ["bar-chart-box-line", "Impact chart"],
        ["route-line", "Track"],
        ["checkbox-multiple-line", "Decide"],
        ["git-branch-line", "Processes"],
        ["wallet-3-line", "Budgets"],
        ["hand-heart-line", "Volunteer"],
        ["calendar-check-line", "Volunteer opportunities"],
        ["medal-line", "Contribution"],
        ["line-chart-line", "Trend"],
        ["group-line", "Community"],
        ["star-line", "Goodwill"],
        ["home-heart-line", "Neighbourhood"],
        ["heart-2-line", "Donations"],
        ["community-line", "Local communities"],
        ["login-box-line", "Sign in"]
      ].freeze

      # Register native Decidim gamification badges driven off the goodwill
      # ledger so the core /profiles/:nickname/badges page surfaces them. The
      # reset lambdas recompute each badge score from OUR source of truth (the
      # cached contribution column / a confirmed+verified check), so core's
      # `Decidim::Gamification.reset_badges` reconciles drift-free. The earn-time
      # writer is Ledger#award (the single seam); see #mirror_badge_score.
      initializer "decidim_bih.goodwill_badges" do
        # Headline badge: recognition tier by lifetime goodwill points. Thresholds
        # mirror the recognition Levels spirit (komšija → heroj) but in the badge's
        # own 0..N level model. reset reads cached_contribution — the SAME running
        # sum award increments — so the increment and the reset never disagree.
        Decidim::Gamification.register_badge(:goodwill_contributor) do |badge|
          badge.levels = [10, 50, 200, 600, 1500]
          badge.reset = lambda do |user|
            Decidim::Bih::Goodwill::Account
              .where(
                organization: user.organization,
                owner_type: user.class.base_class.name,
                owner_id: user.id
              )
              .pick(:cached_contribution).to_i
          end
        end

        # Binary civic-trust badge: lights up once the citizen is confirmed AND
        # holds at least one granted authorization. Cheap, single-threshold.
        Decidim::Gamification.register_badge(:verified_citizen) do |badge|
          badge.levels = [1]
          badge.reset = lambda do |user|
            confirmed = user.respond_to?(:confirmed?) ? user.confirmed? : false
            verified = Decidim::Authorization
                       .where(user:).where.not(granted_at: nil).exists?
            confirmed && verified ? 1 : 0
          end
        end
      end

      # Wire goodwill point-awarding to the reliable AS-notification seams. Done
      # in after_initialize (runs ONCE after boot, when the engine constants are
      # loadable, and NOT re-run on code reload — so subscriptions are never
      # duplicated). The subscriber blocks reference jobs/models by constant name,
      # so Zeitwerk reloading resolves them freshly per call.
      config.after_initialize do
        # Register only icons not already provided by core / decidim_awesome
        # (their register_icons initializers have all run by now), so we never
        # re-register a name they own and trip the deprecation warning.
        MI_ICONS.each do |name, description|
          next if Decidim.icons.all.has_key?(name)

          Decidim.icons.register(name:, icon: name, category: "system", description:, engine: :core)
        end

        Decidim::Bih::Goodwill::EventSubscriptions.install!

        # Durable, Redis-backed integration-health recorder. Subscribes (once,
        # idempotently) to the metadata-only instrumentation event stream and
        # folds it into a per-provider health record the admin integrations page
        # reads. Fully rescued: a failure here must never block boot or break an
        # instrumented call.
        begin
          Decidim::Bih::IntegrationHealth.install!
        rescue StandardError => e
          Rails.logger.warn("[Decidim::Bih::IntegrationHealth] install failed: #{e.class}")
        end

        # Boot-time partial-configuration warning (logs, never raises).
        Decidim::Bih::Config.validate!
      end

      # Capture an inbound referral code (stashed in the session by the invite
      # landing page) and attribute it to a freshly-registered invitee. The
      # block runs per request, so referencing engine constants here is safe.
      #
      # The rules — the 24-hour window, the "registered after the click" guard
      # and the legacy fallback — live in
      # Decidim::Bih::Goodwill::Referrals.attribute_from_session, because this
      # hook is not the only caller: the one-step registration spends the code
      # at POST /registracija, where the session is still intact (see that
      # method for why it has to).
      #
      # The referrer is only REWARDED later, on the invitee's first verification
      # (see the authorization override) — verification is the Sybil gate.
      initializer "decidim_bih.goodwill_referral_capture" do
        Warden::Manager.after_set_user do |user, auth, _opts|
          next unless user.is_a?(Decidim::User)

          session = auth.respond_to?(:env) ? auth.env["rack.session"] : nil
          next if session.nil?

          Decidim::Bih::Goodwill::Referrals.attribute_from_session(session, user)
        rescue StandardError => e
          # A hook that raises breaks the sign-in it is riding on. The service
          # guards its own body; this guards the two lines above it, and logs
          # the class alone for the same reason it does.
          Rails.logger.error("[goodwill] referral capture: #{e.class}")
        end
      end
    end
  end
end
