# frozen_string_literal: true

require "test_helper"
require_relative "../db/migrate/20260915070000_consolidate_decidim_bih_notification_topics"

module Decidim
  module Bih
    module RailsHarness
      class TopicPreferenceMigrationTest < ActiveSupport::TestCase
        MIGRATION = ConsolidateDecidimBihNotificationTopics
        TABLES = %w(decidim_users decidim_bih_messaging_preferences decidim_bih_messaging_preference_changes
                    decidim_bih_messaging_suppressions).freeze

        test "populated matrix consolidates preserving refusals history subscriptions and provider evidence" do
          with_legacy_tables do
            subscriptions = { "device" => { "auth" => "fixture-secret", "p256dh" => "fixture-key", "endpoint" => "https://push.example.test/device" } }
            user = MIGRATION::UserRow.create!(type: "Decidim::User", decidim_organization_id: 9,
                                              notification_settings: { "mi_report_updates_viber" => true,
                                                                       "mi_city_service_alerts_viber" => false,
                                                                       "subscriptions" => subscriptions,
                                                                       "custom_admin_setting" => false })
            old = old_preference(user, topic: "report_updates", state: "allowed")
            event = old_event(user, old)
            suppression = MIGRATION::SuppressionRow.create!(decidim_organization_id: 9, decidim_user_id: user.id,
                                                            channel: "viber", suppressed_at: 2.days.ago)
            original_event = event.attributes
            original_suppression = suppression.attributes

            migrate!

            preferences = MIGRATION::PreferenceRow.where(decidim_user_id: user.id)
            assert_equal 4, preferences.count
            assert_equal "blocked", preferences.find_by!(topic: "neighborhood_info").state
            assert_equal "unknown", preferences.find_by!(topic: "neighborhood_info").source
            assert_equal "allowed", preferences.find_by!(topic: "report_updates").state
            assert_equal "allowed", preferences.find_by!(topic: "platform_news").state
            assert_equal original_event, MIGRATION::ChangeRow.find(event.id).attributes
            assert_equal original_suppression, MIGRATION::SuppressionRow.find(suppression.id).attributes
            assert_equal({ "subscriptions" => subscriptions, "custom_admin_setting" => false }, user.reload.notification_settings)
            assert_not_includes MIGRATION::PreferenceRow.column_names, "channel"
            assert MIGRATION::ChangeRow.exists?(topic: "city_service_alerts", channel: "viber", new_state: "blocked")
            assert_raises(ActiveRecord::RecordNotUnique) do
              ActiveRecord::Base.transaction(requires_new: true) do
                MIGRATION::PreferenceRow.create!(preferences.find_by!(topic: "report_updates").attributes.except("id"))
              end
            end
          end
        end

        test "provider refusal without effective evidence aborts and restores the matrix" do
          with_legacy_tables do
            user = provider_refusal_user
            old_preference(user, source: "provider_opt_out", state: "blocked")
            assert_raises(ActiveRecord::MigrationError) { migrate! }
            MIGRATION::PreferenceRow.reset_column_information
            assert_includes MIGRATION::PreferenceRow.column_names, "channel"
            assert_equal 1, MIGRATION::PreferenceRow.count
            assert_equal false, user.reload.notification_settings["mi_report_updates_viber"]
          end
        end

        test "an older reactivation is not evidence that a later legacy refusal is resolved" do
          with_legacy_tables do
            user = provider_refusal_user
            MIGRATION::SuppressionRow.create!(decidim_organization_id: 9, decidim_user_id: user.id,
                                              channel: "viber", suppressed_at: 4.days.ago, reactivated_at: 3.days.ago)
            assert_raises(ActiveRecord::MigrationError) { migrate! }
          end
        end

        test "active provider block survives and does not disable the entire topic" do
          with_legacy_tables do
            user = provider_refusal_user
            suppression = MIGRATION::SuppressionRow.create!(decidim_organization_id: 9, decidim_user_id: user.id,
                                                            channel: "viber", suppressed_at: 1.day.ago)
            migrate!
            assert_equal "allowed", MIGRATION::PreferenceRow.find_by!(decidim_user_id: user.id, topic: "report_updates").state
            assert_nil suppression.reload.reactivated_at
          end
        end

        private

        def provider_refusal_user
          MIGRATION::UserRow.create!(type: "Decidim::User", decidim_organization_id: 9, notification_settings: {
                                       "mi_report_updates_viber" => false,
                                       "mi_channel_preference_provenance" => {
                                         "mi_report_updates_viber" => { "source" => "provider_opt_out", "changed_at" => 1.day.ago.iso8601 }
                                       }
                                     })
        end

        def old_preference(user, topic: "report_updates", source: "organization_default", state: "allowed")
          MIGRATION::PreferenceRow.create!(decidim_organization_id: 9, decidim_user_id: user.id,
                                           topic:, channel: "viber", state:, source:, policy_version: "old",
                                           change_id: SecureRandom.uuid, changed_at: 1.day.ago)
        end

        def old_event(user, preference)
          MIGRATION::ChangeRow.create!(decidim_organization_id: 9, decidim_user_id: user.id,
                                       topic: preference.topic, channel: preference.channel, new_state: preference.state,
                                       source: preference.source, actor_type: "organization_policy", operation: "organization_default",
                                       change_id: preference.change_id, policy_version: "old", recorded_at: 1.day.ago)
        end

        def migrate!
          ActiveRecord::Migration.suppress_messages do
            ActiveRecord::Base.transaction(requires_new: true) { MIGRATION.new.up }
          end
          MIGRATION::PreferenceRow.reset_column_information
        end

        # Rename only the fixture tables inside a savepoint, retaining their
        # rows and foreign-key targets. Rolling back restores the whole schema.
        # This also works under the generated-host guard: no CREATE SCHEMA,
        # search-path changes, extension changes or cross-schema writes.
        def with_legacy_tables
          connection = ActiveRecord::Base.connection
          token = SecureRandom.hex(6)
          ActiveRecord::Base.transaction(requires_new: true) do
            %w(idx_bih_messaging_prefs_identity idx_bih_messaging_prefs_audience).each_with_index do |name, index|
              connection.rename_index(:decidim_bih_messaging_preferences, name, "topic_index_#{token}_#{index}")
            end
            TABLES.each_with_index do |table, index|
              connection.rename_table(table, "topic_backup_#{token}_#{index}")
            end
            create_old_tables(connection)
            reset_migration_models
            yield
            raise ActiveRecord::Rollback
          end
        ensure
          reset_migration_models
        end

        def reset_migration_models
          [MIGRATION::UserRow, MIGRATION::PreferenceRow, MIGRATION::ChangeRow, MIGRATION::SuppressionRow].each(&:reset_column_information)
        end

        def create_old_tables(connection)
          connection.create_table(:decidim_users) do |table|
            table.string :type
            table.bigint :decidim_organization_id
            table.jsonb :notification_settings, default: {}
          end
          connection.create_table(:decidim_bih_messaging_preferences) do |table|
            table.bigint :decidim_organization_id
            table.bigint :decidim_user_id
            [:topic, :channel, :state, :source, :policy_version, :change_id, :imported_from].each { |name| table.string name }
            table.datetime :changed_at
            table.timestamps
          end
          connection.add_index(:decidim_bih_messaging_preferences, [:decidim_organization_id, :decidim_user_id, :topic, :channel],
                               unique: true, name: "idx_bih_messaging_prefs_identity")
          connection.add_index(:decidim_bih_messaging_preferences, [:decidim_organization_id, :topic, :channel, :state],
                               name: "idx_bih_messaging_prefs_audience")
          connection.add_check_constraint(:decidim_bih_messaging_preferences,
                                          "channel IN ('viber', 'whatsapp', 'messenger', 'instagram')", name: "bih_messaging_prefs_channel")
          connection.add_check_constraint(:decidim_bih_messaging_preferences,
                                          "topic IN ('report_updates', 'community_news', 'city_service_alerts')", name: "bih_messaging_prefs_topic")
          connection.create_table(:decidim_bih_messaging_preference_changes) do |table|
            table.bigint :decidim_organization_id
            table.bigint :decidim_user_id
            [:topic, :channel, :previous_state, :new_state, :previous_source, :source, :actor_type, :operation, :change_id, :policy_version, :ui_revision].each do |name|
              table.string name
            end
            table.datetime :recorded_at
            table.timestamps
          end
          connection.create_table(:decidim_bih_messaging_suppressions) do |table|
            table.bigint :decidim_organization_id
            table.bigint :decidim_user_id
            table.string :channel
            table.datetime :suppressed_at
            table.datetime :reactivated_at
          end
        end
      end
    end
  end
end
