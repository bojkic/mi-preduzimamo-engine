# frozen_string_literal: true

require "test_helper"
require "active_support/concern"
require "active_support/core_ext/object/blank"
require "decidim/bih"
require_relative "../../../../app/controllers/concerns/decidim/bih/current_organization_user"
require_relative "../../../../app/services/decidim/bih/citizen_return_path"

module Decidim
  unless const_defined?(:ApplicationController, false)
    class ApplicationController
      def self.helper_method(*); end
    end
  end
end

require_relative "../../../../app/controllers/decidim/bih/volunteer_controller"

module Decidim
  module Bih
    class VolunteerReturnTest < Minitest::Test
      Organization = Struct.new(:id)
      User = Struct.new(:organization)

      class Routes
        def new_user_session_path(redirect_url:)
          ["/sign-in", redirect_url]
        end
      end

      class ControllerProbe < VolunteerController
        attr_accessor :user, :organization, :request_params
        attr_reader :redirected_to, :index_loaded

        def initialize
          @session = {}
        end

        def current_user = user

        def current_organization = organization

        def params = request_params

        def session = @session

        def decidim = Routes.new

        def redirect_to(path) = (@redirected_to = path)

        def load_index_data = (@index_loaded = true)
      end

      def setup
        @controller = ControllerProbe.new
        @controller.organization = Organization.new(42)
      end

      def test_anonymous_private_tabs_redirect_with_the_exact_selected_destination
        %w(dostupnost predlozi moje).each do |tab|
          controller = ControllerProbe.new
          controller.organization = @controller.organization
          controller.request_params = { tab:, sign_in: "1", opportunity_id: "77" }
          destination = "#{Decidim::Bih.public_path('volontiranje')}?tab=#{tab}"

          controller.index

          assert_equal ["/sign-in", destination], controller.redirected_to
          assert_equal destination, CitizenReturnPath.consume(controller.session, organization: controller.organization)
          refute controller.index_loaded
        end
      end

      def test_anonymous_tab_visit_without_sign_in_request_renders_that_tab
        @controller.request_params = { tab: "predlozi" }

        @controller.index

        assert @controller.index_loaded
        assert_nil @controller.redirected_to
        assert_empty @controller.session
      end

      def test_unrecognized_tab_cannot_be_stored_as_a_sign_in_destination
        @controller.request_params = { tab: "../moj-nalog", sign_in: "1" }

        @controller.index

        assert @controller.index_loaded
        assert_nil @controller.redirected_to
        assert_empty @controller.session
      end

      def test_authenticated_visit_does_not_replace_a_pending_return_or_redirect
        @controller.user = User.new(@controller.organization)
        @controller.request_params = { tab: "moje", sign_in: "1" }
        pending = Decidim::Bih.public_path("moj-nalog")
        CitizenReturnPath.store(@controller.session, organization: @controller.organization, path: pending)

        @controller.index

        assert @controller.index_loaded
        assert_nil @controller.redirected_to
        assert_equal pending, CitizenReturnPath.consume(@controller.session, organization: @controller.organization)
      end

      def test_other_tenant_user_still_enters_sign_in_and_return_stays_tenant_bound
        @controller.user = User.new(Organization.new(43))
        @controller.request_params = { tab: "moje", sign_in: "1" }

        @controller.index

        assert_equal ["/sign-in", "#{Decidim::Bih.public_path('volontiranje')}?tab=moje"], @controller.redirected_to
        assert_nil CitizenReturnPath.consume(@controller.session, organization: Organization.new(43))
        assert_empty @controller.session
      end
    end
  end
end
