# frozen_string_literal: true

require "test_helper"
require "active_support/concern"
require File.expand_path("../../../../../../app/controllers/concerns/decidim/bih/admin/scoped_finder", __dir__)

module Decidim
  module Bih
    module Admin
      class ScopedFinderTest < Minitest::Test
        Record = Struct.new(:reference, keyword_init: true)

        class PrivateControllerProbe
          include Decidim::Bih::Admin::ScopedFinder
        end

        class Scope
          attr_reader :find_by_calls

          def self.find_by(**_conditions)
            raise "global model lookup must not be used"
          end

          def initialize(record:)
            @record = record
            @find_by_calls = []
          end

          def find_by(**conditions)
            @find_by_calls << conditions
            @record
          end
        end

        class ControllerProbe
          include Decidim::Bih::Admin::ScopedFinder

          attr_reader :flash, :redirected_to, :translations

          def initialize
            @flash = {}
            @translations = []
          end

          def t(key)
            @translations << key
            "translation:#{key}"
          end

          def redirect_to(path)
            @redirected_to = path
          end

          public :find_scoped!
        end

        def setup
          @controller = ControllerProbe.new
        end

        def test_find_scoped_is_private_on_including_controller
          assert_includes PrivateControllerProbe.private_instance_methods, :find_scoped!
        end

        def test_returns_record_from_passed_scope
          record = Record.new(reference: "R-1")
          scope = Scope.new(record:)

          result = @controller.find_scoped!(
            scope,
            redirect_to: "/admin/bih/reports",
            flash_key: "decidim.bih.admin.reports.not_found",
            reference: "R-1"
          )

          assert_same record, result
          assert_equal [{ reference: "R-1" }], scope.find_by_calls
          assert_empty @controller.flash
          assert_nil @controller.redirected_to
        end

        def test_missing_record_sets_requested_flash_redirects_to_requested_path_and_returns_nil
          scope = Scope.new(record: nil)

          result = @controller.find_scoped!(
            scope,
            redirect_to: -> { "/admin/bih/reports" },
            flash_key: "decidim.bih.admin.reports.not_found",
            reference: "missing"
          )

          assert_nil result
          assert_equal "translation:decidim.bih.admin.reports.not_found", @controller.flash[:alert]
          assert_equal "/admin/bih/reports", @controller.redirected_to
          assert_equal ["decidim.bih.admin.reports.not_found"], @controller.translations
          assert_equal [{ reference: "missing" }], scope.find_by_calls
        end

        def test_uses_passed_scope_not_scope_class_lookup
          record = Record.new(reference: "scoped")
          scope = Scope.new(record:)

          result = @controller.find_scoped!(
            scope,
            redirect_to: "/fallback",
            flash_key: "unused",
            id: 42
          )

          assert_same record, result
          assert_equal [{ id: 42 }], scope.find_by_calls
        end
      end
    end
  end
end
