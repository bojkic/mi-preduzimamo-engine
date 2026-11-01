# frozen_string_literal: true

require "test_helper"

module Decidim
  unless const_defined?(:ActionForbidden, false)
    class ActionForbidden < StandardError
    end
  end

  module Admin
    unless const_defined?(:ApplicationController, false)
      class ApplicationController
        class << self
          attr_reader :layout_name, :before_actions

          def layout(name)
            @layout_name = name
          end

          def before_action(name, *)
            @before_actions ||= []
            @before_actions << name
          end

          def skip_before_action(*); end

          def helper_method(*); end
        end
      end
    end
  end
end

if Decidim.const_defined?(:Bih, false) &&
   Decidim::Bih.const_defined?(:Admin, false) &&
   Decidim::Bih::Admin.const_defined?(:ApplicationController, false) &&
   Decidim::Bih::Admin::ApplicationController.superclass != Decidim::Admin::ApplicationController
  Decidim::Bih::Admin.send(:remove_const, :ApplicationController)
end

require_relative "../../../../../app/controllers/decidim/bih/admin/application_controller"

module Decidim
  module Bih
    module Admin
      class ApplicationControllerTest < Minitest::Test
        User = Struct.new(:admin, :organization, keyword_init: true) do
          def admin?
            admin
          end
        end

        Organization = Struct.new(:id, keyword_init: true)

        class ControllerProbe < ApplicationController
          attr_accessor :user, :organization, :permissions

          public :ensure_bih_operator_access!, :ensure_global_admin!, :bih_allowed?, :current_bih_permissions

          def current_user
            user
          end

          def current_organization
            organization
          end

          def current_bih_permissions
            permissions || []
          end
        end

        def test_admin_user_passes_bih_operator_access_gate
          controller = ControllerProbe.new
          organization = Organization.new(id: 1)
          controller.organization = organization
          controller.user = User.new(admin: true, organization:)
          controller.permissions = ["operations_read"]

          assert_nil controller.ensure_bih_operator_access!
        end

        def test_admin_without_scoped_permissions_is_forbidden
          controller = ControllerProbe.new
          controller.organization = Organization.new(id: 1)
          controller.user = User.new(admin: true, organization: Organization.new(id: 2))

          assert_raises(Decidim::ActionForbidden) { controller.ensure_bih_operator_access! }
          assert_raises(Decidim::ActionForbidden) { controller.ensure_global_admin! }
        end

        def test_operator_with_permissions_passes_bih_operator_access_gate
          controller = ControllerProbe.new
          organization = Organization.new(id: 1)
          controller.organization = organization
          controller.user = User.new(admin: false, organization:)
          controller.permissions = ["reports_read"]

          assert_nil controller.ensure_bih_operator_access!
        end

        def test_user_without_operator_permissions_is_forbidden
          controller = ControllerProbe.new
          organization = Organization.new(id: 1)
          controller.organization = organization
          controller.user = User.new(admin: false, organization:)

          assert_raises Decidim::ActionForbidden do
            controller.ensure_bih_operator_access!
          end
        end

        def test_missing_user_is_forbidden
          controller = ControllerProbe.new

          assert_raises Decidim::ActionForbidden do
            controller.ensure_bih_operator_access!
          end
        end

        def test_global_admin_gate_still_restricts_admin_only_actions
          controller = ControllerProbe.new
          controller.user = User.new(admin: false, organization: Organization.new(id: 1))

          assert_raises Decidim::ActionForbidden do
            controller.ensure_global_admin!
          end
        end

        def test_admin_layout_is_declared_when_using_pure_stub_base
          skip "real Decidim admin controller loaded" unless Decidim::Admin::ApplicationController.respond_to?(:layout_name)

          assert_equal "decidim/bih/admin", ApplicationController.layout_name
        end

        def test_bih_operator_gate_is_registered_when_using_pure_stub_base
          skip "real Decidim admin controller loaded" unless Decidim::Admin::ApplicationController.respond_to?(:before_actions)

          assert_includes ApplicationController.before_actions, :ensure_bih_operator_access!
        end
      end
    end
  end
end
