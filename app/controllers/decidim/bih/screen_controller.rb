# frozen_string_literal: true

module Decidim
  module Bih
    # The venue screen for the 17.9. launch: a projector page with big numbers.
    #
    # No login, read-only, aggregate only — it is displayed to a hall full of
    # people and must never render a name, a phone number or report content.
    #
    # RESILIENCE: the first paint is server-rendered and every figure is also
    # written into data- attributes. The 30-second refresh only REPLACES those
    # numbers on success; when the venue network drops, the last good figures
    # stay on screen and no error is ever shown.
    class ScreenController < Decidim::ApplicationController
      REFRESH_MS = 30_000
      TOP_N = 8
      SETTINGS_NAMESPACE = "screen"

      skip_before_action :store_current_location, raise: false
      layout false

      def show
        response.cache_control.replace(no_store: true)
        @figures = figures
        @wifi = wifi

        respond_to do |format|
          format.html
          format.json { render json: @figures }
        end
      end

      private

      def standings
        @standings ||= Decidim::Bih::Race::Standings.new(current_organization)
      end

      def rows
        @rows ||= standings.rows
      end

      def figures
        visible = Decidim::Bih::Race::Visibility.visible?(current_organization)
        return { scores_visible: false, updated_at: standings.computed_at&.iso8601 } unless visible
        {
          scores_visible: true,
          registered: rows.sum(&:registered),
          reports: rows.sum(&:reports),
          komsiluci_with_reports: rows.count { |row| row.reports.positive? },
          leaders: Decidim::Bih::LocalArea::ZONES.index_with { |zone| leader_payload(standings.leader(zone)) },
          top: rows.first(TOP_N).map { |row| row_payload(row) },
          updated_at: standings.computed_at&.iso8601
        }
      end

      def leader_payload(standing)
        return nil unless standing

        { name: standing.display_name, score: standing.score }
      end

      def row_payload(row)
        {
          rank: row.rank_overall,
          name: row.display_name,
          zona: row.zona,
          score: row.score
        }
      end

      # Venue wifi is operator-editable and shown ONLY here. It must never reach
      # an export or a log.
      def wifi
        settings = Decidim::Bih::Setting.namespace_for(current_organization, SETTINGS_NAMESPACE)
        { ssid: settings["wifi_ssid"], password: settings["wifi_password"] }
      end
    end
  end
end
