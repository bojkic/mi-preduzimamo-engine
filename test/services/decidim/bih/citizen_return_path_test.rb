# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/citizen_return_path"

module Decidim
  module Bih
    class CitizenReturnPathTest < Minitest::Test
      Organization = Struct.new(:id)

      def setup
        @organization = Organization.new(42)
        @session = {}
      end

      def test_preserves_only_a_fixed_citizen_get_destination_once
        path = Decidim::Bih.public_path("moj-nalog/poruke")

        assert CitizenReturnPath.store(@session, organization: @organization, path:)
        assert_equal path, CitizenReturnPath.consume(@session, organization: @organization)
        assert_nil CitizenReturnPath.consume(@session, organization: @organization)
      end

      def test_rejects_token_paths_external_urls_and_unexpected_queries
        [
          Decidim::Bih.public_path("prijave/MI-123/status/secret"),
          "#{Decidim::Bih.public_path('moj-nalog/poruke')}?redirect_url=//elsewhere.example",
          "#{Decidim::Bih.public_path('prijave')}?view=mine&q=private",
          "//elsewhere.example/moj-nalog",
          "https://elsewhere.example/moj-nalog"
        ].each do |path|
          refute CitizenReturnPath.store(@session, organization: @organization, path:), path
          assert_empty @session
        end
      end

      def test_report_destination_keeps_only_the_private_list_intent
        path = "#{Decidim::Bih.public_path('prijave')}?view=mine"

        assert CitizenReturnPath.store(@session, organization: @organization, path:)
        assert_equal path, CitizenReturnPath.consume(@session, organization: @organization)
      end

      def test_submission_destinations_are_exact_get_paths
        %w(organizacije/nova projekti/novi).each do |suffix|
          path = Decidim::Bih.public_path(suffix)
          assert CitizenReturnPath.store(@session, organization: @organization, path:)
          assert_equal path, CitizenReturnPath.consume(@session, organization: @organization)
          refute CitizenReturnPath.store(@session, organization: @organization, path: "#{path}?redirect_url=//elsewhere.example")
          refute CitizenReturnPath.store(@session, organization: @organization, path: "#{path}/../moj-nalog")
          assert_empty @session
        end
      end

      def test_volunteering_destinations_keep_only_a_fixed_private_tab
        %w(dostupnost predlozi moje).each do |tab|
          path = "#{Decidim::Bih.public_path('volontiranje')}?tab=#{tab}"
          assert CitizenReturnPath.store(@session, organization: @organization, path:)
          assert_equal path, CitizenReturnPath.consume(@session, organization: @organization)
          refute CitizenReturnPath.store(@session, organization: @organization, path: "#{path}&opportunity_id=1")
          assert_empty @session
        end
      end

      def test_other_tenant_and_expired_destinations_are_discarded
        path = Decidim::Bih.public_path("moj-doprinos")
        assert CitizenReturnPath.store(@session, organization: @organization, path:)
        assert_nil CitizenReturnPath.consume(@session, organization: Organization.new(43))

        assert CitizenReturnPath.store(@session, organization: @organization, path:)
        @session[CitizenReturnPath::KEY]["expires_at"] = Time.now.to_i - 60
        assert_nil CitizenReturnPath.consume(@session, organization: @organization)
      end
    end
  end
end
