# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module Admin
      unless const_defined?(:ApplicationController, false)
        class ApplicationController
          def self.before_action(*); end

          def self.controller_path
            "decidim/bih/admin/application"
          end
        end
      end
    end
  end
end

require_relative "../../../../../app/controllers/decidim/bih/admin/broadcasts_controller"

module Decidim
  module Bih
    module Admin
      class BroadcastsControllerHelpersTest < Minitest::Test
        class ControllerProbe < BroadcastsController
          attr_reader :redirect

          def new_admin_bih_board_notice_path
            "/admin/bih/board-notices/new"
          end

          def redirect_to(path, **options)
            @redirect = [path, options]
          end

          def t(key)
            key
          end

          def params
            raise "Retired broadcasts must not consume stale audience or channel parameters"
          end
        end

        def test_legacy_bookmark_opens_the_durable_notice_composer
          controller = ControllerProbe.new
          controller.new

          assert_equal ["/admin/bih/board-notices/new", {}], controller.redirect
        end

        def test_stale_confirmation_redirects_with_review_required_without_reading_send_parameters
          controller = ControllerProbe.new
          2.times do
            controller.create

            assert_equal ["/admin/bih/board-notices/new", { alert: "decidim.bih.admin.board_notices.legacy_redirect" }], controller.redirect
          end
        end
      end
    end
  end
end
