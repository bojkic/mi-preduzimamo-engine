# frozen_string_literal: true

require "decidim/bih/topic_preference_migration"

# The old matrix remains in append-only history. The current state becomes
# exactly one row per user/topic; device subscriptions and identities are kept.
class ConsolidateDecidimBihNotificationTopics < ActiveRecord::Migration[7.2]
  class UserRow < ActiveRecord::Base
    self.table_name = "decidim_users"
    self.inheritance_column = :_type_disabled
  end

  class PreferenceRow < ActiveRecord::Base
    self.table_name = "decidim_bih_messaging_preferences"
  end

  class ChangeRow < ActiveRecord::Base
    self.table_name = "decidim_bih_messaging_preference_changes"
  end

  class SuppressionRow < ActiveRecord::Base
    self.table_name = "decidim_bih_messaging_suppressions"
  end

  TRANSFORM = Decidim::Bih::TopicPreferenceMigration
  VERSION = "mi-topics-2026-09-15"
  IMPORT = "topic_consolidation_20260915"

  def up
    remove_check_constraint :decidim_bih_messaging_preferences, name: "bih_messaging_prefs_channel"
    remove_check_constraint :decidim_bih_messaging_preferences, name: "bih_messaging_prefs_topic"
    remove_index :decidim_bih_messaging_preferences, name: "idx_bih_messaging_prefs_identity"
    remove_index :decidim_bih_messaging_preferences, name: "idx_bih_messaging_prefs_audience"
    PreferenceRow.reset_column_information

    UserRow.where(type: "Decidim::User").where.not(decidim_organization_id: nil).find_each do |user|
      user.with_lock { consolidate(user) }
    end

    # A dangling or different STI owner is unexpected and must not lose data.
    raise ActiveRecord::MigrationError, "Unmigrated notification owners; inspect preference ownership before retrying" if PreferenceRow.where.not(channel: "topic").exists?

    remove_column :decidim_bih_messaging_preferences, :channel, :string
    add_index :decidim_bih_messaging_preferences,
              [:decidim_organization_id, :decidim_user_id, :topic],
              unique: true, name: "idx_bih_messaging_prefs_identity"
    add_index :decidim_bih_messaging_preferences,
              [:decidim_organization_id, :topic, :state], name: "idx_bih_messaging_prefs_audience"
    add_check_constraint :decidim_bih_messaging_preferences,
                         "topic IN ('report_updates', 'community_news', 'platform_news', 'neighborhood_info')",
                         name: "bih_messaging_prefs_topic"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Topic consolidation preserves historical choices; restore the reviewed pre-migration snapshot to restore matrix code"
  end

  private

  def consolidate(user)
    current = PreferenceRow.where(decidim_user_id: user.id, decidim_organization_id: user.decidim_organization_id)
    settings = user.notification_settings.to_h
    snapshot = TRANSFORM.snapshot(settings:, preferences: current.map(&:attributes))
    verify_provider_blocks!(user, snapshot.fetch(:provider_blocks))
    snapshot.fetch(:entries).each { |entry| archive_entry(user, entry) }
    current.delete_all
    snapshot.fetch(:choices).each do |topic, choice|
      persist_topic(user, topic, choice)
    end
    # This anonymous model has no runtime callbacks. The locked update retains
    # every unrelated setting, including the full push subscription objects.
    user.update!(notification_settings: TRANSFORM.cleaned_settings(settings))
  end

  def verify_provider_blocks!(user, entries)
    entries.each do |entry|
      evidence = SuppressionRow.where(
        decidim_organization_id: user.decidim_organization_id,
        decidim_user_id: user.id, channel: entry.fetch(:channel)
      )
      known_stop_time = entry[:changed_at].present? ? historical_time(entry[:changed_at]) : nil
      covered = evidence.exists?(reactivated_at: nil)
      covered ||= known_stop_time && evidence.exists?(reactivated_at: known_stop_time..)
      next if covered

      raise ActiveRecord::MigrationError,
            "Legacy provider refusal lacks suppression evidence; reconcile provider blocks before topic consolidation"
    end
  end

  def archive_entry(user, entry)
    change_id = entry[:change_id]
    return if change_id.present? && ChangeRow.exists?(change_id:)

    ChangeRow.create!(
      decidim_organization_id: user.decidim_organization_id, decidim_user_id: user.id,
      topic: entry.fetch(:legacy_topic), channel: entry.fetch(:channel),
      previous_state: nil, new_state: entry.fetch(:state), previous_source: nil,
      source: entry.fetch(:source), actor_type: "system_import", operation: "import",
      change_id: change_id.presence || SecureRandom.uuid,
      policy_version: VERSION, ui_revision: IMPORT, recorded_at: historical_time(entry[:changed_at])
    )
  end

  def persist_topic(user, topic, choice)
    now = Time.current
    change_id = SecureRandom.uuid
    PreferenceRow.create!(
      decidim_organization_id: user.decidim_organization_id, decidim_user_id: user.id,
      topic:, channel: "topic", state: choice.fetch(:state), source: choice.fetch(:source),
      change_id:, changed_at: historical_time(choice[:changed_at]),
      policy_version: VERSION, imported_from: IMPORT
    )
    ChangeRow.create!(
      decidim_organization_id: user.decidim_organization_id, decidim_user_id: user.id,
      topic:, channel: "topic", previous_state: nil, new_state: choice.fetch(:state),
      previous_source: nil, source: choice.fetch(:source),
      actor_type: "system_import", operation: "import", change_id:,
      policy_version: VERSION, ui_revision: IMPORT, recorded_at: now
    )
  end

  def historical_time(value)
    value.present? ? Time.zone.parse(value.to_s) : Time.current
  end
end
