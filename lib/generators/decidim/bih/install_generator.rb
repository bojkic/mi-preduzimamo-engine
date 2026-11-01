# frozen_string_literal: true

require "rails/generators/base"
require "decidim/bih"

module Decidim
  module Bih
    module Generators
      # Generates the host-side contract stubs needed before exposing the BIH
      # public engine in a new Decidim app.
      class InstallGenerator < Rails::Generators::Base
        namespace "decidim:bih:install"

        desc "Generate decidim-bih host initializer, public assets, throttles, and checklist"
        source_root File.expand_path("templates", __dir__)

        class_option :mount_path,
                     type: :string,
                     default: Decidim::Bih.public_mount_path,
                     desc: "Public mount path for Decidim::Bih::Engine"
        class_option :short_magic_links,
                     type: :boolean,
                     default: true,
                     desc: "Emit short /v/:token magic links through a host route"
        class_option :skip_assets,
                     type: :boolean,
                     default: false,
                     desc: "Do not copy packaged public assets into public/"
        class_option :force_assets,
                     type: :boolean,
                     default: false,
                     desc: "Overwrite existing public assets when copying packaged files"
        class_option :skip_rack_attack,
                     type: :boolean,
                     default: false,
                     desc: "Do not generate the Rack::Attack throttle initializer"
        class_option :skip_docs,
                     type: :boolean,
                     default: false,
                     desc: "Do not generate docs/decidim_bih_host_contract.md"

        def copy_initializer
          template "decidim_bih.rb.erb", "config/initializers/decidim_bih.rb"
        end

        def copy_public_assets
          return if options[:skip_assets]

          result = Decidim::Bih.install_required_public_assets!(
            public_root: File.join(destination_root, "public"),
            overwrite: options[:force_assets]
          )
          say_status :copy,
                     "public assets (#{result.fetch(:copied).size} copied, " \
                     "#{result.fetch(:skipped).size} skipped)"
        end

        def copy_rack_attack_initializer
          return if options[:skip_rack_attack]

          template "decidim_bih_rack_attack.rb.erb",
                   "config/initializers/decidim_bih_rack_attack.rb"
        end

        def write_host_contract_doc
          return if options[:skip_docs]

          create_file "docs/decidim_bih_host_contract.md", host_contract_doc
        end

        private

        def mount_path
          Decidim::Bih.normalize_public_mount_path(options[:mount_path])
        end

        def short_magic_links?
          options[:short_magic_links]
        end

        def short_magic_links_literal
          short_magic_links? ? "true" : "false"
        end

        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def host_contract_doc
          asset_rows = Decidim::Bih.required_public_asset_manifest.map do |asset|
            "- `#{asset.fetch(:public_path)}` -> `public/#{asset.fetch(:relative_path)}`"
          end

          throttle_rows = Decidim::Bih.required_public_throttles_for_mount(
            mount_path:,
            short_magic_links: short_magic_links?
          ).map do |throttle|
            paths = Array(throttle[:paths]) +
                    Array(throttle[:path_regexes]).map { |path| "regex: #{path}" }
            "- `#{throttle.fetch(:id)}` (`#{throttle.fetch(:name)}`): " \
              "#{throttle.fetch(:methods).join(", ")} #{paths.join(", ")}; " \
              "limit #{throttle.fetch(:limit)} per #{throttle.fetch(:period)}s by " \
              "#{throttle.fetch(:discriminator)}"
          end

          public_write_rows = Decidim::Bih.required_public_write_routes_for_mount(mount_path:).map do |route|
            paths = Array(route[:paths]).join(", ")
            throttle = Array(route[:throttle_ids]).any? ? "throttles #{route.fetch(:throttle_ids).join(", ")}" : "no throttle: #{route.fetch(:no_throttle_reason)}"
            "- `#{route.fetch(:id)}`: #{route.fetch(:methods).join(", ")} #{paths}; " \
              "auth `#{route.fetch(:auth)}`; #{throttle}"
          end

          surface_rows = Decidim::Bih.required_public_surface_manifest(mount_path:).map do |surface|
            menu = surface[:menu_i18n_key] || "none"
            "- `#{surface.fetch(:id)}`: #{surface.fetch(:methods).join(", ")} " \
              "#{surface.fetch(:paths).join(", ")}; menu `#{menu}`; " \
              "review #{surface.fetch(:host_review_flags).join(", ")}"
          end

          brand_asset_rows = Decidim::Bih.required_brand_asset_reviews.map do |asset|
            "- `#{asset.fetch(:id)}`: #{asset.fetch(:public_paths).join(", ")} - " \
              "#{asset.fetch(:review_note)}"
          end

          decidim_module_rows = Decidim::Bih.required_decidim_modules.map do |mod|
            "- `#{mod.fetch(:gem)}` (`#{mod.fetch(:status)}`): " \
              "#{mod.fetch(:reason)}"
          end

          privacy_bucket_rows = Decidim::Bih.required_privacy_retention_buckets.map do |bucket|
            handler = if bucket[:service_cutoff_key]
                        "`#{bucket.fetch(:env_cutoff_key)}` -> `#{bucket.fetch(:service_cutoff_key)}`"
                      else
                        duration = bucket[:retention_hours] ? "#{bucket.fetch(:retention_hours)} hours" : "#{bucket.fetch(:retention_days)} days"
                        "`#{bucket.fetch(:lifecycle_service)}` (#{duration})"
                      end
            "- `#{bucket.fetch(:id)}`: #{handler}; #{bucket.fetch(:action)}; #{bucket.fetch(:removes)}"
          end

          audit_stream_rows = Decidim::Bih.required_audit_event_streams.map do |stream|
            "- `#{stream.fetch(:id)}`: #{stream.fetch(:storage)}; stores " \
              "#{stream.fetch(:stores)} Excludes: #{stream.fetch(:excluded_pii).first(5).join(", ")}."
          end

          <<~MARKDOWN
            # Decidim BIH Host Contract

            Generated by `bin/rails generate decidim:bih:install`.

            ## Required Routes

            Add these routes before any catch-all Decidim root mount:

            ```ruby
            mount Decidim::Bih::Engine => "#{mount_path}"
            # Required only when Decidim::Bih.magic_link_short_path_enabled is true.
            get "/v/:token", to: "decidim/bih/magic_links#show"
            post "/v/:token", to: "decidim/bih/magic_links#consume"
            # Required only if this host accepts Infobip/Viber inbound messages.
            post "#{mount_path}/viber/webhook", to: "your_host/viber/webhook#create"
            # Required only for each Infobip-managed external chat channel the host enables.
            post "#{mount_path}/whatsapp/webhook", to: "your_host/infobip/whatsapp#create"
            post "#{mount_path}/messenger/webhook", to: "your_host/infobip/messenger#create"
            post "#{mount_path}/instagram/webhook", to: "your_host/infobip/instagram#create"
            ```

            Provider webhooks are intentionally host routes because each host
            owns the fail-closed secret-header check, explicit channel launch
            gate and inbound provider wiring. Keep them mounted before the
            Decidim catch-all route and protect them with the generated
            Rack::Attack throttles.

            ## Public Mount And Magic Links

            - Public mount path: `#{mount_path}`
            - Short root magic links: `#{short_magic_links_literal}`

            ## Public Surface Review

            Review these route ids, expanded paths, menu i18n keys, and local
            product vocabulary before launching a second host. Stable paths can
            stay as compatibility routes, but labels, examples, provider copy,
            notification policy, and privacy promises must fit the host.

            #{surface_rows.join("\n")}

            ## Required Public Assets

            The generator copied the packaged files below into the host app's
            `public/` directory unless it was run with `--skip-assets`. It does
            not overwrite existing host-customized files unless
            `--force-assets` is used.

            Treat `/mi/*` as a required compatibility namespace, not as a brand
            contract. Review the copied theme, mark, sticker, chat, and PWA
            files before launching a second host; replace their contents with
            local branding while preserving the required public paths.

            To refresh the same asset set later:

            ```sh
            bundle exec rake decidim_bih:host_contract:install_assets
            OVERWRITE=1 bundle exec rake decidim_bih:host_contract:install_assets
            ```

            #{asset_rows.join("\n")}

            ## Brand Asset Review

            The `/mi/*` namespace is a compatibility namespace, not a required
            brand name. Review or replace these packaged asset families while
            preserving the required public paths. The engine playbook is
            `docs/BRAND_ASSET_REPLACEMENT.md` in the `decidim-bih` checkout.

            #{brand_asset_rows.join("\n")}

            ## Hard Decidim Module Dependencies

            The engine currently declares these Decidim modules as runtime gem
            dependencies. Treat them as required for second-host boot until a
            separate feature-flag pass proves smaller module sets with boot and
            workflow tests:

            #{decidim_module_rows.join("\n")}

            ## Required Public Write Throttles

            Review `config/initializers/decidim_bih_rack_attack.rb` before
            production launch. The generated throttle names, limits, and periods
            mirror `Decidim::Bih.required_public_throttles`.

            #{throttle_rows.join("\n")}

            ## Public Write Route Classification

            Every public write route must either reference one of the required
            throttle ids above or explain why a throttle is not required. Review
            these decisions when adding routes, provider calls, costly AI work,
            or high-volume citizen actions.

            #{public_write_rows.join("\n")}

            ## Privacy And Audit Event Contract

            The privacy/audit-event contract is machine-readable through
            `Decidim::Bih.privacy_audit_contract_manifest`,
            `rake decidim_bih:host_contract:privacy_audit`, and the full
            host-contract manifest. It is template-only: never paste real report
            references, contacts, addresses, coordinates, provider payloads,
            tokens, raw logs, or free text into generated docs or CI evidence.

            Retention buckets:

            #{privacy_bucket_rows.join("\n")}

            Audit, analytics, and public aggregate streams:

            #{audit_stream_rows.join("\n")}

            ## Required Host Wiring

            Configure the host-specific providers in
            `config/initializers/decidim_bih.rb`: donations, concierge/city data,
            Goodwill schedule and rewards, map center/zoom, geocoder user agent,
            flagship process/campaign settings, PWA short name, and optional
            Viber bot URI.
          MARKDOWN
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      end
    end
  end
end
