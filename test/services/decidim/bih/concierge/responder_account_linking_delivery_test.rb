# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require_relative "../../../../../app/services/decidim/bih/concierge/responder"

module Decidim
  module Bih
    module Concierge
      class ResponderAccountLinkingDeliveryTest < Minitest::Test
        class Linking
          def initialize(status)
            @status = status
          end

          def start(sender:, phone:)
            [sender, phone]
            @status
          end
        end

        class Session
          attr_reader :sets

          def initialize
            @sets = []
          end

          def set(sender:, state:)
            sets << { sender:, state: }
          end
        end

        class HostFreeResponder < Responder
          def initialize(status:, session:, production:)
            @account_linking = Linking.new(status)
            @session_store = session
            @production = production
          end

          def submit_phone_for_test(sender, phone)
            submit_phone(sender, phone)
          end

          private

          def production_environment?
            @production
          end

          def t(key, **)
            key
          end
        end

        def test_production_unconfigured_delivery_returns_failure_without_advancing_state
          session = Session.new
          reply = responder(:unconfigured, session:, production: true).submit_phone_for_test("opaque-sender", "065123456")

          assert_equal "link.send_failed", reply.text
          assert_empty session.sets
        end

        def test_nonproduction_unconfigured_delivery_preserves_offline_code_flow
          session = Session.new
          reply = responder(:unconfigured, session:, production: false).submit_phone_for_test("opaque-sender", "065123456")

          assert_equal "link.code_sent", reply.text
          assert_equal [{ sender: "opaque-sender", state: Responder::STATE_AWAITING_CODE }], session.sets
        end

        def test_production_success_advances_to_code_entry
          session = Session.new
          reply = responder(:otp_sent, session:, production: true).submit_phone_for_test("opaque-sender", "065123456")

          assert_equal "link.code_sent", reply.text
          assert_equal [{ sender: "opaque-sender", state: Responder::STATE_AWAITING_CODE }], session.sets
        end

        private

        def responder(status, session:, production:)
          HostFreeResponder.new(status:, session:, production:)
        end
      end
    end
  end
end
