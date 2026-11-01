# frozen_string_literal: true

require "test_helper"
require_relative "../../../../lib/decidim/bih/topic_preference_migration"

module Decidim
  module Bih
    class TopicPreferenceMigrationTest < Minitest::Test
      def snapshot(settings = {}, preferences = [])
        TopicPreferenceMigration.snapshot(settings:, preferences:)
      end

      def test_absence_enables_exactly_four_topics_without_claiming_a_citizen_choice
        choices = snapshot.fetch(:choices)
        assert_equal %w(community_news neighborhood_info platform_news report_updates), choices.keys.sort
        assert(choices.values.all? { |choice| choice[:state] == "allowed" && choice[:source] == "organization_default" })
      end

      def test_false_on_one_channel_disables_only_its_topic
        choices = snapshot("mi_report_updates_viber" => true, "mi_report_updates_whatsapp" => false).fetch(:choices)
        assert_equal "blocked", choices.fetch("report_updates")[:state]
        assert_equal "allowed", choices.fetch("community_news")[:state]
        assert_equal "allowed", choices.fetch("platform_news")[:state]
      end

      def test_incomplete_new_table_does_not_hide_a_legacy_false
        row = { "topic" => "city_service_alerts", "channel" => "whatsapp", "state" => "allowed", "source" => "organization_default" }
        choice = snapshot({ "mi_city_service_alerts_viber" => false }, [row]).fetch(:choices).fetch("neighborhood_info")
        assert_equal "blocked", choice[:state]
        assert_equal "unknown", choice[:source]
      end

      def test_normalized_false_survives_true_legacy_json
        row = { "topic" => "community_news", "channel" => "viber", "state" => "blocked", "source" => "account" }
        choice = snapshot({ "mi_community_news_viber" => true }, [row]).fetch(:choices).fetch("community_news")
        assert_equal "blocked", choice[:state]
        assert_equal "account", choice[:source]
      end

      def test_both_legacy_neighborhood_switches_map_to_the_combined_topic
        %w(komsiluk_board mi_komsiluk_urgent_bell).each do |key|
          assert_equal "blocked", snapshot(key => false).fetch(:choices).fetch("neighborhood_info")[:state]
        end
      end

      def test_provider_stop_is_separate_from_the_citizen_topic_choice
        settings = {
          "mi_community_news_viber" => false,
          "mi_channel_preference_provenance" => { "mi_community_news_viber" => { "source" => "provider_opt_out" } }
        }
        result = snapshot(settings)
        assert_equal "allowed", result.fetch(:choices).fetch("community_news")[:state]
        assert_equal "viber", result.fetch(:provider_blocks).first[:channel]
        assert_equal 1, result.fetch(:provider_blocks).length
      end

      def test_cleanup_preserves_subscriptions_and_unrelated_settings_exactly
        subscriptions = { "device" => { "auth" => "test-auth", "endpoint" => "https://push.example.test/device", "p256dh" => "test-public-key" } }
        settings = { "subscriptions" => subscriptions, "admin_custom" => false, "mi_report_updates_viber" => false,
                     "mi_channel_preference_provenance" => {}, "komsiluk_board" => false }
        clean = TopicPreferenceMigration.cleaned_settings(settings)
        assert_equal({ "subscriptions" => subscriptions, "admin_custom" => false }, clean)
        assert_equal false, settings["mi_report_updates_viber"], "the snapshot itself stays untouched"
      end

      def test_invalid_old_boolean_requires_review_instead_of_silently_enabling
        assert_raises(ArgumentError) { snapshot("mi_report_updates_viber" => "maybe") }
      end
    end
  end
end
