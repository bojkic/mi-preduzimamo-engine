# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/numeric/time"
require "active_support/time"
require "logger"
require "decidim/bih"
require_relative "../../../../app/services/decidim/bih/integration_health"

module Decidim
  module Bih
    # A high-impact send is blocked by EVIDENCE that the provider is failing,
    # never by the absence of evidence. This tally is written only by real
    # outbound phone traffic, so silence is the ordinary state; treating it as
    # "not ready" hid the Viber controls almost all the time.
    class IntegrationHealthSendBlockedTest < Minitest::Test
      def setup
        # #state rescues everything and logs; without a logger in this pure
        # minitest suite the rescue itself raises and hides the real failure.
        Rails.logger ||= Logger.new(IO::NULL) if defined?(Rails)
        # #to_time goes through Time.zone, which this pure-minitest suite does
        # not set up; without it #state silently rescues into an empty state.
        Time.zone ||= "UTC"
        @health = IntegrationHealth.new(store: IntegrationHealth::MemoryStore.new)
      end

      def test_a_provider_with_no_record_at_all_does_not_block
        assert_equal :unknown, status
        refute @health.send_blocked?(provider: "infobip")
      end

      def test_a_recent_success_does_not_block
        record_success(at: Time.zone.now.to_i)

        assert_equal :ok, status
        refute @health.send_blocked?(provider: "infobip")
      end

      def test_silence_since_the_last_success_does_not_block
        record_success(at: (Time.zone.now - 3600).to_i)

        assert_equal :stale, status, "an hour of no outbound traffic is stale, not broken"
        refute @health.send_blocked?(provider: "infobip")
      end

      def test_silence_since_the_last_failure_does_not_block
        record_failure(at: (Time.zone.now - 3600).to_i)

        assert_equal :stale, status
        refute @health.send_blocked?(provider: "infobip"), "an old failure is not evidence about now"
      end

      def test_a_recent_failure_blocks
        record_success(at: (Time.zone.now - 120).to_i)
        record_failure(at: Time.zone.now.to_i)

        assert_equal :failing, status
        assert @health.send_blocked?(provider: "infobip")
      end

      def test_a_success_after_a_recent_failure_clears_the_block
        record_failure(at: (Time.zone.now - 120).to_i)
        record_success(at: Time.zone.now.to_i)

        assert_equal :ok, status
        refute @health.send_blocked?(provider: "infobip")
      end

      def test_one_provider_failing_never_blocks_another
        record_failure(at: Time.zone.now.to_i)

        assert @health.send_blocked?(provider: "infobip")
        refute @health.send_blocked?(provider: "odoo")
      end

      private

      def status = @health.state(provider: "infobip").to_h[:status]

      def record_success(at:)
        @health.send(:store).record_success(provider: "infobip", organization: "global", at:)
      end

      def record_failure(at:)
        @health.send(:store).record_failure(provider: "infobip", organization: "global", at:, error_code: "500", error_class: "Decidim::Bih::Infobip::Error")
      end
    end
  end
end
