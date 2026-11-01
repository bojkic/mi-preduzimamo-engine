# frozen_string_literal: true

require "test_helper"
require "yaml"

module Decidim
  module Bih
    class ReportAndVolunteerAssistanceTest < Minitest::Test
      ROOT = File.expand_path("../../../..", __dir__)
      LOCALES = %w(en sr bs hr sr-Cyrl).freeze
      REQUIRED_KEYS = %w(
        reports.new.location.use_current
        reports.new.location.find_address
        reports.new.location.map_toggle
        reports.new.photo.choose
        reports.new.hints.anonymous_signed_in
        reports_map.show.loading
        reports_map.show.ready
        reports_map.show.empty
        reports_map.show.unavailable
        reports_map.show.retry
        reports_map.show.list_fallback
        volunteer.index.signup_deadline
        volunteer.index.signup_deadline_closed_help
        volunteer.index.lifecycle.title
        volunteer.index.lifecycle.attendance
        volunteer.index.lifecycle.points
        volunteer.index.opportunity_proposal.schedule_timezone_hint
        volunteer.flash.signup_deadline_closed
      ).freeze

      def test_report_and_volunteer_assistance_exists_in_every_maintained_locale
        LOCALES.each do |locale|
          tree = YAML.safe_load_file(File.join(ROOT, "config/locales/#{locale}.yml"), aliases: true)
          scope = tree.fetch(locale).fetch("decidim").fetch("bih")

          REQUIRED_KEYS.each do |key|
            value = key.split(".").reduce(scope) { |node, segment| node.fetch(segment) }
            refute_empty value.to_s, "#{locale} is missing #{key}"
          end
        end
      end

      def test_task_views_set_localized_page_titles
        views = %w(
          app/views/decidim/bih/reports/new.html.erb
          app/views/decidim/bih/reports/index.html.erb
          app/views/decidim/bih/reports/show.html.erb
          app/views/decidim/bih/reports/duplicate.html.erb
          app/views/decidim/bih/reports_map/show.html.erb
          app/views/decidim/bih/report_heatmap/index.html.erb
          app/views/decidim/bih/volunteer/index.html.erb
        )

        views.each do |relative_path|
          assert_includes File.read(File.join(ROOT, relative_path)), "add_decidim_page_title"
        end
      end
    end
  end
end
