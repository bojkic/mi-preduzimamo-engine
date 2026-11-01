# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/outcome"
require_relative "../../../../../app/services/decidim/bih/account_notifications"

module Decidim
  module Bih
    # `AccountNotifications::ROUTED_NOTIFICATION_STATUS` is written with literal
    # Symbols so that file stays loadable by this suite, which boots no Rails
    # and has no messaging constants. That is only safe while the Outcome
    # vocabulary IS those symbols — otherwise a renamed outcome would silently
    # fall through to "unknown" on a real send instead of failing loudly.
    class RoutedStatusVocabularyTest < Minitest::Test
      def map
        AccountNotifications.const_get(:ROUTED_NOTIFICATION_STATUS)
      end

      def test_every_outcome_has_a_legacy_status
        missing = Messaging::Outcome::ALL - map.keys
        assert_empty missing, "outcomes with no legacy status: #{missing.inspect}"
      end

      def test_the_map_invents_no_outcome_of_its_own
        invented = map.keys - Messaging::Outcome::ALL - [Messaging::Outcome::EXPIRED]
        assert_empty invented, "keys that are not outcomes: #{invented.inspect}"
      end

      def test_every_status_is_one_the_legacy_record_accepts
        legacy_statuses = %w(pending sending accepted rejected failed unknown skipped delivered)
        assert_empty map.values.uniq - legacy_statuses
      end
    end
  end
end
