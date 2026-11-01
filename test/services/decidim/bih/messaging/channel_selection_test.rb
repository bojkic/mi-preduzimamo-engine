# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/channel_selection"

module Decidim
  module Bih
    module Messaging
      class ChannelSelectionTest < Minitest::Test
        def test_live_suitable_session_avoids_a_paid_copy
          assert_equal ["messenger"], ChannelSelection.external(%w(viber whatsapp messenger instagram))
          assert_equal ["instagram"], ChannelSelection.external(%w(whatsapp instagram))
        end

        def test_without_eligible_session_one_managed_fallback_chain_remains
          assert_equal %w(viber whatsapp), ChannelSelection.external(%w(whatsapp viber))
          assert_equal ["whatsapp"], ChannelSelection.external(%w(whatsapp))
        end

        def test_unrequested_or_ineligible_channels_are_never_added
          assert_empty ChannelSelection.external([])
          assert_empty ChannelSelection.external(%w(sms))
          assert_equal ["email"], ChannelSelection.external(%w(viber whatsapp email))
          assert_equal ["instagram"], ChannelSelection.external(%w(instagram))
        end
      end
    end
  end
end
