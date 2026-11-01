# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      # Builds the tappable civic-shortcut chips shown UNDER the bot's
      # help/fallback reply: describe a problem to the bot, open the report
      # form, propose an idea, the city budget, donate, Goodwill points, setup
      # and Komsiluk. Labels come from the existing
      # decidim.bih.concierge.widget.quick.* i18n keys (rendered in the given
      # reply locale), URLs from the engine's own route helpers and the live
      # participation-component paths.
      #
      # Two chip shapes exist, and every chip has exactly one of them:
      #   { label:, url: }  — navigates to a page;
      #   { label:, send: } — sends a canned message to the bot instead.
      # The report entry is deliberately split into both: "describe it to the
      # bot" starts the guided intake in chat, "form with a photo" jumps to the
      # intake form for citizens who already know what they want to file.
      #
      # This is a CHIP MENU for the help reply only — first-time / low-literacy
      # visitors get a one-tap jump into the key flows. It is NOT shown on
      # substantive answers (status, budget, waste, …), so the chips read as
      # "here's where to start" rather than noise. Chip-incapable channels
      # (Viber) simply ignore the field.
      #
      # Every URL is resolved defensively: a resolution failure drops THAT chip
      # rather than breaking the help reply, so a half-configured org still gets
      # whatever shortcuts do resolve.
      class CivicShortcuts
        # +organization+ scopes the flagship-process lookup; +locale+ is the
        # reply script (Latin or sr-Cyrl) the chip labels render in. +routes+
        # defaults to the engine's own URL helpers; tests inject a stand-in.
        def initialize(organization:, locale: "sr", routes: nil)
          @organization = organization
          @locale = locale
          @routes = routes
        end

        # The ordered chip list; chips whose target could not be resolved are
        # dropped.
        def chips
          [
            send_chip("report_describe", report_describe_message),
            chip("report_form", report_url),
            chip("idea", proposals_url),
            chip("budget", budgets_url),
            chip("donate", donate_url),
            chip("goodwill", goodwill_url),
            chip("setup", setup_url),
            chip("komsiluk", komsiluk_url)
          ].compact
        end

        private

        attr_reader :organization, :locale

        def chip(key, url)
          return nil if url.blank?

          { label: label(key), url: url }
        end

        # A chip that talks to the bot: tapping it submits +message+ as the
        # citizen's next turn instead of leaving the conversation.
        def send_chip(key, message)
          return nil if message.blank?

          { label: label(key), send: message }
        end

        def label(key)
          I18n.t("decidim.bih.concierge.widget.quick.#{key}", locale: locale)
        end

        def report_describe_message
          I18n.t("decidim.bih.concierge.widget.quick.report_describe_send", locale: locale)
        rescue StandardError
          nil
        end

        def report_url
          engine_routes.new_report_path
        rescue StandardError
          nil
        end

        def donate_url
          engine_routes.community_projects_path
        rescue StandardError
          nil
        end

        def goodwill_url
          engine_routes.wallet_path
        rescue StandardError
          nil
        end

        def setup_url
          engine_routes.verification_explainer_path
        rescue StandardError
          nil
        end

        def komsiluk_url
          engine_routes.komsiluk_board_index_path
        rescue StandardError
          nil
        end

        # The live "propose an idea" target: the flagship process's proposals
        # component, falling back to the process page. Mirrors MiHeroCell's
        # component-path resolution so the chip tracks the homepage CTA.
        def proposals_url
          component_path("proposals") || process_path
        end

        # The live "city budget" target: the flagship process's budgets
        # component, falling back to the process page.
        def budgets_url
          component_path("budgets") || process_path
        end

        def component_path(manifest_name)
          process = flagship_process
          return nil unless process

          component = process.components.published.find_by(manifest_name: manifest_name)
          return nil unless component

          Decidim::EngineRouter.main_proxy(component).root_path
        rescue StandardError
          nil
        end

        def process_path
          return nil if process_slug.empty?

          "/processes/#{process_slug}"
        end

        def flagship_process
          return @flagship_process if defined?(@flagship_process)
          return @flagship_process = nil if process_slug.empty?

          @flagship_process = Decidim::ParticipatoryProcess
                              .where(organization: organization).published
                              .find_by(slug: process_slug)
        rescue StandardError
          @flagship_process = nil
        end

        def process_slug
          Decidim::Bih.flagship_process_slug.to_s.strip
        end

        def engine_routes
          @routes || Decidim::Bih::Engine.routes.url_helpers
        end
      end
    end
  end
end
