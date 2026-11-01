# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "json"
require "faraday"
require "decidim/bih/instrumentation"
require_relative "../../../../../app/services/decidim/bih/log_redactor"
require_relative "../../../../../app/services/decidim/bih/odoo/error"
require_relative "../../../../../app/services/decidim/bih/odoo/client"
require_relative "../../../../../app/services/decidim/bih/infobip/error"

module Decidim
  module Bih
    module Odoo
      class ClientPrivacyTest < Minitest::Test
        PRIVATE_MARKER = "invented-private-provider-body-marker"

        def test_fault_does_not_copy_provider_text_into_exception_or_cause
          client = client_for(JSON.generate(error: { code: 200, data: { message: PRIVATE_MARKER } }))
          error = assert_raises(Error) { client.uid }

          assert_equal "Odoo fault", error.message
          assert_nil error.cause
          refute_includes error.full_message, PRIVATE_MARKER
        end

        def test_malformed_body_does_not_survive_as_parser_cause
          error = assert_raises(Error) { client_for("#{PRIVATE_MARKER} not-json").uid }

          assert_equal "Odoo returned non-JSON", error.message
          assert_nil error.cause
          refute_includes error.full_message, PRIVATE_MARKER
        end

        def test_valid_rpc_response_keeps_authentication_result
          assert_equal 42, client_for(JSON.generate(result: 42)).uid
        end

        def test_instrumentation_drops_an_existing_cause_even_when_outer_message_is_safe
          wrapped = exception_with_cause(ArgumentError.new("safe provider summary"))
          error = assert_raises(ArgumentError) do
            Instrumentation.instrument("test.provider.cause") { raise wrapped }
          end

          assert_equal "safe provider summary", error.message
          assert_nil error.cause
          refute_includes error.full_message, PRIVATE_MARKER
        end

        def test_instrumentation_preserves_bounded_provider_diagnostics
          wrapped = exception_with_cause(Infobip::Error.new("safe provider summary", http_status: 429,
                                                                                   error_code: "RATE_LIMITED"))
          error = assert_raises(Infobip::Error) do
            Instrumentation.instrument("test.provider.diagnostics") { raise wrapped }
          end

          assert_equal 429, error.http_status
          assert_equal "RATE_LIMITED", error.error_code
          assert_nil error.cause
          refute_includes error.full_message, PRIVATE_MARKER
        end

        private

        def client_for(body)
          stubs = Faraday::Adapter::Test::Stubs.new do |stub|
            stub.post("/jsonrpc") { [200, { "Content-Type" => "application/json" }, body] }
          end
          client = Client.new(base_url: "https://provider.example.invalid", db: "fixture", login: "fixture",
                              api_key: "test-api-key-123456")
          client.instance_variable_set(:@connection, Faraday.new(url: "https://provider.example.invalid") do |connection|
            connection.adapter :test, stubs
          end)
          client
        end

        def exception_with_cause(outer)
          begin
            raise StandardError, PRIVATE_MARKER
          rescue StandardError
            begin
              raise outer
            rescue StandardError => wrapped
              wrapped
            end
          end
        end
      end
    end
  end
end
