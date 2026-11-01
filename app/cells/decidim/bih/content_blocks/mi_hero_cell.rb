# frozen_string_literal: true

module Decidim
  module Bih
    module ContentBlocks
      # Homepage "MI hero" content block: the activist poster stack from the
      # MI PRE(D)UZIMAMO! design kit (eyebrow, MI + verbs wordwall, sub copy,
      # two CTAs, trust line), a live-activity ticker card and an org-scoped
      # stats strip. Data-light — copy comes from i18n
      # (decidim.bih.content_blocks.mi_hero.*), styling from the host theme
      # (public/mi/mi-theme.css: .mi-hero / .mi-ticker / .mi-hero-stats).
      class MiHeroCell < Decidim::ViewModel
        include Decidim::SanitizeHelper

        delegate :current_organization, to: :controller

        # The flagship participation process the CTAs deep-link into. The host
        # selects the slug; when it is absent, the CTA falls back to /processes.
        TICKER_SIZE = 6

        # Stats that are never hidden by Decidim::Bih.mi_hero_stat_min: the
        # campaign amount is a fixed promise and the invitation counter is a
        # remaining stock — neither says anything about how busy the platform
        # looks — and the total of problem reports is the campaign's headline
        # figure, wanted on the homepage from the very first report rather
        # than only once it clears the launch-mode floor.
        UNFILTERED_STAT_KEYS = %w(campaign launch_invitations reports_total reports_sent).freeze

        # The poster words under the big "MI" — color split (white / sava /
        # sun) comes from the matching .mi-poster-word--w* theme classes.
        def poster_words
          %w(w2 w3 w4)
        end

        def primary_cta_href
          component_root_path("proposals") || process_fallback_path
        end

        def secondary_cta_href
          component_root_path("budgets") || process_fallback_path
        end

        def registered_user?
          current_organization_user.present?
        end

        def registration_cta_href
          Decidim::Bih.registration_path
        end

        def account_cta_href
          Decidim::Bih.public_path("moj-doprinos")
        end

        # A signed-in citizen is sent to their contribution page instead of a
        # registration form they no longer need.
        def account_or_registration_href
          registered_user? ? account_cta_href : registration_cta_href
        end

        # Buttons under the poster. The default keeps the three the design kit
        # shipped; a host running launch mode supplies its own list through
        # Decidim::Bih.mi_hero_ctas — an Array of
        # { label_key:, signed_in_label_key: (optional), href: (String | :registration),
        #   style: "primary"|"ghost", icon: (optional), chat: true|false },
        # or a Proc returning one.
        def hero_ctas
          configured = resolve_config(Decidim::Bih.mi_hero_ctas)
          return default_ctas if configured.blank?

          configured.map do |cta|
            {
              label: t(cta_label_key(cta)),
              href: cta[:href] == :registration ? account_or_registration_href : cta[:href],
              style: cta[:style].to_s == "primary" ? "mi-btn--primary" : "mi-btn--ghost-light",
              icon: cta[:icon].presence,
              chat: cta[:chat] == true
            }
          end
        end

        def default_ctas
          [
            { label: t_scope("cta_primary"), href: primary_cta_href, style: "mi-btn--primary",
              icon: "megaphone-line", chat: false },
            { label: t_scope("cta_secondary"), href: secondary_cta_href, style: "mi-btn--ghost-light",
              icon: nil, chat: false },
            { label: t_scope(registered_user? ? "register.signed_in_cta" : "register.cta"),
              href: account_or_registration_href, style: "mi-btn--sun", icon: nil, chat: false }
          ]
        end

        # Host route (config/routes.rb, Task 13) for the race rules page. The
        # campaign stats tile links here so the fixed "6.000 KM" figure
        # actually explains itself. Hardcoded like the other host paths above
        # — this cell has no host route helper access, only the host's own
        # plain path strings.
        def campaign_stat_href
          "/trka"
        end

        def registration_panel_benefits
          [
            { icon: "copper-coin-line", text: t_scope("register.benefits.points") },
            { icon: "chat-3-line", text: t_scope("register.benefits.komsiluk") },
            { icon: "map-pin-line", text: t_scope("register.benefits.reports") },
            { icon: "shield-check-line", text: t_scope("register.benefits.verification") }
          ]
        end

        # Public civic entries plus core's moderated public activity feed.
        # No member-only activity is included, even for signed-in visitors.
        # Empty Array — the template omits the ticker card entirely.
        def ticker_activities
          @ticker_activities ||= begin
            entries = HomepageActivity.new(current_organization, limit: TICKER_SIZE).call + core_ticker_activities
            recent = entries.sort_by { |entry| -entry.created_at.to_f }
            # Reserve one place per public activity type before filling with
            # recent entries, so a batch of opportunities cannot hide reports.
            representatives = recent.uniq { |entry| entry.is_a?(HomepageActivity::Entry) ? entry.kind : :participation }
            (representatives.first(TICKER_SIZE) + (recent - representatives)).first(TICKER_SIZE)
                                                                             .sort_by { |entry| -entry.created_at.to_f }
          end
        end

        def core_ticker_activities
          @core_ticker_activities ||= begin
            picked = []
            viewer = nil
            last_activity_query.each do |activity|
              break if picked.size == TICKER_SIZE
              next unless activity.visible_for?(viewer)
              next if ticker_title(activity).blank?
              # Deleted accounts keep their action logs but lose their name —
              # an empty <b></b> actor on the public homepage reads broken.
              next if ticker_actor_name(activity).blank?

              picked << activity
            end
            picked
          rescue StandardError => e
            Rails.logger.error("[mi_hero] ticker: #{e.class}: #{e.message}")
            []
          end
        end

        def ticker_actor_name(activity)
          return t("decidim.bih.homepage_activity.kinds.#{activity.kind}") if activity.is_a?(HomepageActivity::Entry)

          user = activity.user
          return decidim_html_escape(user.presenter.name) if user.is_a?(Decidim::User)

          decidim_escape_translated(current_organization.name)
        end

        def ticker_action_phrase(activity)
          return "" if activity.is_a?(HomepageActivity::Entry)

          t(
            activity.action.to_s,
            scope: "decidim.bih.content_blocks.mi_hero.ticker.actions",
            default: t_scope("ticker.actions.default")
          )
        end

        def ticker_title(activity)
          return decidim_html_escape(activity.title) if activity.is_a?(HomepageActivity::Entry)

          resource = activity.resource_lazy
          title = resource.try(:resource_title) || resource.try(:title)
          case title
          when String then decidim_html_escape(title)
          when Hash then decidim_escape_translated(title)
          end
        rescue StandardError
          nil
        end

        def ticker_path(activity)
          return activity.path if activity.is_a?(HomepageActivity::Entry)

          resource_locator(activity.resource_lazy).path
        rescue StandardError
          nil
        end

        def ticker_time(activity)
          t_scope("ticker.time_ago", time: time_ago_in_words(activity.created_at))
        end

        def ticker_icon(activity)
          if activity.is_a?(HomepageActivity::Entry)
            name = { report: "map-pin-line", volunteering: "shield-check-line",
                     organization: "community-line", notice: "megaphone-line" }.fetch(activity.kind)
            return icon(name, role: "img", "aria-hidden": true)
          end

          resource_type_icon(activity.resource_lazy.class, role: "img", "aria-hidden": true)
        rescue StandardError
          icon "other", role: "img", "aria-hidden": true
        end

        # Pre-formatted org stats ({ key:, value: } Hashes); empty Array hides
        # the whole strip. Computation, caching and per-stat rescue live in
        # Decidim::Bih::MiHeroStats. The launch-invitation counter is bolted
        # on afterwards (aggregate-only, same source as the rewards tab) so
        # the naslovna and nagrade pages always agree on the same number.
        def stats
          @stats ||= begin
            base = Decidim::Bih::MiHeroStats.for(current_organization)
            remaining = remaining_launch_invitations
            # enabled? MORA ostati — remaining vraća 0 poslije potrošene
            # zalihe, a 0.present? je true u Ruby-ju. Bez ove provjere bi
            # naslovna trajno pokazivala "0 pozivnica" i poslije 16.9., jer
            # enabled? je jedino mjesto koje provjerava reward.expired?.
            if remaining.present? && Decidim::Bih::Goodwill::LaunchInvitation.enabled?(current_organization)
              base + [{ key: "launch_invitations", value: remaining.to_s, count: remaining }]
            else
              base
            end
          end
        end

        # A thin activity counter reads as an empty platform, so a host can set
        # a floor under which the tile is dropped rather than shown. Tiles that
        # are not activity counters (see UNFILTERED_STAT_KEYS) and tiles with no
        # count at all (a percentage is not a countable value) always render.
        def stat_visible?(stat)
          return true if UNFILTERED_STAT_KEYS.include?(stat[:key].to_s)
          return true if stat[:count].nil?

          stat[:count].to_i >= stat_minimum
        end

        # Resolved once per render, not once per tile: mi_hero_stat_min may be
        # a Proc, and a host's Proc must not be called four times for one page.
        # (0 is truthy in Ruby, so ||= memoizes the default correctly.)
        def stat_minimum
          @stat_minimum ||= resolve_config(Decidim::Bih.mi_hero_stat_min).to_i
        end

        # The strip renders these, not #stats — an all-hidden strip must
        # disappear entirely rather than leave an empty divider behind.
        def visible_stats
          @visible_stats ||= stats.select { |stat| stat_visible?(stat) }
        end

        def t_scope(key, **)
          t(key, scope: "decidim.bih.content_blocks.mi_hero", **)
        end

        def heart_mark_path
          "/mi/heart-mark.webp"
        end

        # Javni brojač preostalih pozivnica u tekućem talasu — agregat, bez
        # ijednog identiteta. Isti keš ključ kao CommunityHubData, pa naslovna
        # i stranica nagrada uvijek pokazuju isti broj.
        def remaining_launch_invitations
          Rails.cache.fetch(
            "goodwill:launch-invitation:remaining:#{current_organization.id}",
            expires_in: 60.seconds
          ) { Decidim::Bih::Goodwill::LaunchInvitation.remaining(current_organization) }
        rescue StandardError => e
          Rails.logger.error("[mi_hero] remaining_launch_invitations: #{e.class}")
          nil
        end

        private

        # Host config may be a plain value or a callable that computes it per
        # request (the same shape provider_contracts and the web chat resolver
        # already accept). Positional callables receive the current tenant;
        # zero-positional and keyword-only callables retain their original
        # invocation contract.
        def resolve_config(value)
          return value unless value.respond_to?(:call)

          args = config_accepts_organization?(value) ? [current_organization] : []
          value.call(*args)
        end

        def config_accepts_organization?(value)
          callable = value.is_a?(Proc) || value.is_a?(Method) ? value : value.method(:call)
          callable.parameters.any? { |type, _name| [:req, :opt, :rest].include?(type) }
        end

        # A :registration button changes destination for a signed-in citizen
        # (account page, not a sign-up form), so its LABEL has to change too —
        # otherwise launch mode invites an already-registered citizen to
        # "Registruj se" and sends them to /moj-doprinos. Hosts supply
        # signed_in_label_key for that case; without it the single label_key
        # is used for both states, as before.
        def cta_label_key(cta)
          return cta[:label_key] unless registered_user?

          cta[:signed_in_label_key].presence || cta[:label_key]
        end

        def last_activity_query
          Decidim::LastActivity
            .new(current_organization, current_user: nil)
            .query
            .limit(TICKER_SIZE * 6)
            .includes([:user])
        end

        def current_organization_user
          Decidim::Bih.organization_scoped_user(current_user, current_organization)
        end

        def process_fallback_path
          process_slug.empty? ? "/processes" : "/processes/#{process_slug}"
        end

        def flagship_process
          return @flagship_process if defined?(@flagship_process)
          return @flagship_process = nil if process_slug.empty?

          @flagship_process =
            Decidim::ParticipatoryProcess.where(organization: current_organization).published.find_by(slug: process_slug)
        rescue StandardError
          @flagship_process = nil
        end

        def process_slug
          Decidim::Bih.flagship_process_slug.to_s.strip
        end

        def component_root_path(manifest_name)
          return unless flagship_process

          component = flagship_process.components.published.find_by(manifest_name:)
          return unless component

          Decidim::EngineRouter.main_proxy(component).root_path
        rescue StandardError
          nil
        end
      end
    end
  end
end
