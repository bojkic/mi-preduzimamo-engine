# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/messaging/effective_setting"
require_relative "../../../../app/services/decidim/bih/account_channel_status"

module Decidim
  module Bih
    # The channel status already knows WHY a channel is unusable; until now it
    # kept that to itself and handed the page a bare state name. The settings
    # page has to say the reason in citizen language, so the mapping from state
    # to reason key lives here, next to the states it explains, and is checked
    # against the one list of reason keys the page can translate.
    class AccountChannelStatusReasonsTest < Minitest::Test
      PRODUCIBLE_STATES = %w(verified_phone phone_missing connected session_closed not_connected unavailable).freeze

      def test_every_state_the_class_can_produce_has_a_reason_entry
        PRODUCIBLE_STATES.each do |state|
          assert AccountChannelStatus::STATE_REASONS.has_key?(state),
                 "state #{state} has no reason mapping; the page would show a blocked channel with no explanation"
        end
      end

      def test_no_extra_state_is_mapped
        assert_equal PRODUCIBLE_STATES.sort, AccountChannelStatus::STATE_REASONS.keys.sort
      end

      def test_every_reason_is_one_the_page_can_translate
        AccountChannelStatus::STATE_REASONS.each_value do |reason|
          next if reason.nil?

          assert_includes Messaging::EffectiveSetting::REASON_KEYS, reason
        end
      end

      def test_an_available_channel_has_no_reason
        assert_nil AccountChannelStatus.reason_for("verified_phone")
        assert_nil AccountChannelStatus.reason_for("connected")
      end

      def test_an_unavailable_channel_names_its_reason
        assert_equal "no_verified_phone", AccountChannelStatus.reason_for("phone_missing")
        assert_equal "no_connected_channel", AccountChannelStatus.reason_for("not_connected")
        assert_equal "session_expired", AccountChannelStatus.reason_for("session_closed")
        assert_equal "channel_not_configured", AccountChannelStatus.reason_for("unavailable")
      end

      def test_an_unknown_state_is_nil_rather_than_an_invented_reason
        assert_nil AccountChannelStatus.reason_for("something_new")
      end
    end
  end
end
