# frozen_string_literal: true

# Task 1.2 of the communication consolidation plan: additive storage only.
#
# Four separate stores because these are four separate things, and the whole
# point of the exercise is that they stop being conflated:
#
#   preferences            what a citizen currently wants, per topic/channel
#   preference_changes     how that came to be — append-only, no content
#   suppressions           what a TRANSPORT refuses to carry (provider STOP,
#                          hard bounce, complaint). Never a topic choice.
#   organization_policies  the tenant's versioned defaults and supported set
#
# Plus the logical-intent structure. The plan asks for an explicit choice
# between extending Decidim::Bih::AccountNotification and adding a parent
# intent; this migration takes the parent-intent option, for three reasons the
# existing table cannot satisfy:
#
#   * one logical message can have MANY attempts (per-device push fan-out is
#     several real deliveries of one intent), while an AccountNotification row
#     is one intent AND one attempt at once;
#   * a recipient without an account (an anonymous report contact, an external
#     institution) cannot be stored at all — decidim_user_id is NOT NULL there;
#   * its encrypted payload is purpose-bound to optional external copies, and
#     authentication secrets must never be duplicated into a general ledger.
#
# A `channel_family` column on the existing table would have addressed none of
# those. AccountNotification is left exactly as it is and is REFERENCED from an
# intent, so the legacy record keeps its meaning and its callers.
class CreateDecidimBihMessagingStorage < ActiveRecord::Migration[7.2]
  TOPICS = %w(report_updates community_news city_service_alerts).freeze
  TOPIC_CHANNELS = %w(viber whatsapp messenger instagram).freeze
  STATES = %w(allowed blocked).freeze
  SOURCES = %w(account provider_opt_out organization_default legacy_import unknown).freeze

  def change
    create_table :decidim_bih_messaging_preferences do |t|
      t.references :decidim_organization, null: false, index: false,
                                          foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user, null: false, index: false,
                                  foreign_key: { to_table: :decidim_users, on_delete: :cascade }
      t.string :topic, null: false
      t.string :channel, null: false
      t.string :state, null: false
      t.string :source, null: false
      t.string :policy_version, null: false
      t.string :change_id, null: false
      t.datetime :changed_at, null: false
      # Where an imported row came from, when it was imported rather than
      # chosen. Null for a live write.
      t.string :imported_from
      t.timestamps
    end
    add_index :decidim_bih_messaging_preferences,
              [:decidim_organization_id, :decidim_user_id, :topic, :channel],
              unique: true, name: :idx_bih_messaging_prefs_identity
    add_index :decidim_bih_messaging_preferences, [:decidim_organization_id, :topic, :channel, :state],
              name: :idx_bih_messaging_prefs_audience
    add_index :decidim_bih_messaging_preferences, [:decidim_organization_id, :updated_at],
              name: :idx_bih_messaging_prefs_batch
    add_check_constraint :decidim_bih_messaging_preferences,
                         "topic IN (#{sql_in_list(TOPICS)})", name: :bih_messaging_prefs_topic
    add_check_constraint :decidim_bih_messaging_preferences,
                         "channel IN (#{sql_in_list(TOPIC_CHANNELS)})", name: :bih_messaging_prefs_channel
    add_check_constraint :decidim_bih_messaging_preferences,
                         "state IN (#{sql_in_list(STATES)})", name: :bih_messaging_prefs_state
    add_check_constraint :decidim_bih_messaging_preferences,
                         "source IN (#{sql_in_list(SOURCES)})", name: :bih_messaging_prefs_source

    create_table :decidim_bih_messaging_preference_changes do |t|
      t.references :decidim_organization, null: false, index: false,
                                          foreign_key: { to_table: :decidim_organizations }
      # Nullify rather than cascade: an anonymisation must be able to drop the
      # person without erasing the operational record that a change happened.
      t.references :decidim_user, null: true, index: false,
                                  foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.string :topic, null: false
      t.string :channel, null: false
      t.string :previous_state
      t.string :new_state, null: false
      t.string :previous_source
      t.string :source, null: false
      t.string :actor_type, null: false
      t.bigint :actor_id
      t.string :operation, null: false
      t.string :change_id, null: false
      t.string :policy_version, null: false
      t.string :ui_revision
      t.datetime :recorded_at, null: false
      t.timestamps
    end
    add_index :decidim_bih_messaging_preference_changes,
              [:decidim_organization_id, :decidim_user_id, :recorded_at],
              name: :idx_bih_messaging_pref_changes_user
    add_index :decidim_bih_messaging_preference_changes, :change_id, name: :idx_bih_messaging_pref_changes_change
    add_check_constraint :decidim_bih_messaging_preference_changes,
                         "new_state IN (#{sql_in_list(STATES)})", name: :bih_messaging_pref_changes_new_state
    add_check_constraint :decidim_bih_messaging_preference_changes,
                         "previous_state IS NULL OR previous_state IN (#{sql_in_list(STATES)})",
                         name: :bih_messaging_pref_changes_prev_state

    create_table :decidim_bih_messaging_suppressions do |t|
      t.references :decidim_organization, null: false, index: false,
                                          foreign_key: { to_table: :decidim_organizations }
      # A suppression can exist with no account behind it at all: a provider
      # STOP from a number nobody on this platform owns is still a refusal.
      t.references :decidim_user, null: true, index: false,
                                  foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.string :provider, null: false
      t.string :channel, null: false
      t.string :destination_kind, null: false
      t.string :destination_digest, null: false
      t.integer :address_version, null: false, default: 1
      t.string :reason, null: false
      t.string :source, null: false
      t.datetime :suppressed_at, null: false
      t.datetime :reactivated_at
      t.string :reactivation_evidence
      t.timestamps
    end
    add_index :decidim_bih_messaging_suppressions,
              [:decidim_organization_id, :provider, :channel, :destination_digest, :address_version],
              unique: true, name: :idx_bih_messaging_suppressions_identity
    add_index :decidim_bih_messaging_suppressions,
              [:decidim_organization_id, :channel, :reactivated_at],
              name: :idx_bih_messaging_suppressions_active

    create_table :decidim_bih_messaging_organization_policies do |t|
      t.references :decidim_organization, null: false, index: false,
                                          foreign_key: { to_table: :decidim_organizations }
      t.string :policy_version, null: false
      t.jsonb :defaults, null: false, default: {}
      t.jsonb :supported_combinations, null: false, default: {}
      t.datetime :effective_from, null: false
      t.boolean :active, null: false, default: false
      t.timestamps
    end
    add_index :decidim_bih_messaging_organization_policies,
              [:decidim_organization_id, :policy_version],
              unique: true, name: :idx_bih_messaging_org_policies_version
    add_index :decidim_bih_messaging_organization_policies,
              [:decidim_organization_id, :active], name: :idx_bih_messaging_org_policies_active

    create_table :decidim_bih_messaging_intents do |t|
      t.references :decidim_organization, null: false, index: false,
                                          foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user, null: true, index: false,
                                  foreign_key: { to_table: :decidim_users, on_delete: :nullify }
      t.references :decidim_bih_account_notification, null: true, index: false,
                                                      foreign_key: { to_table: :decidim_bih_account_notifications,
                                                                     on_delete: :nullify }
      t.string :message_class, null: false
      t.string :recipient_kind, null: false
      # A safe reference for a recipient with no account: a digest or an opaque
      # identifier, never an address, a token or a push endpoint.
      t.string :recipient_reference
      t.string :correlation_key, null: false
      t.string :deduplication_scope, null: false
      t.string :status, null: false, default: "planned"
      t.string :mode, null: false, default: "shadow"
      t.string :policy_version, null: false
      t.string :eligibility_version, null: false
      t.string :context_digest
      t.jsonb :reason_codes, null: false, default: []
      t.datetime :expires_at
      t.timestamps
    end
    add_index :decidim_bih_messaging_intents,
              [:decidim_organization_id, :deduplication_scope, :correlation_key],
              unique: true, name: :idx_bih_messaging_intents_dedupe
    add_index :decidim_bih_messaging_intents,
              [:decidim_organization_id, :message_class, :created_at],
              name: :idx_bih_messaging_intents_class
    add_index :decidim_bih_messaging_intents, :decidim_bih_account_notification_id,
              name: :idx_bih_messaging_intents_legacy

    create_table :decidim_bih_messaging_attempts do |t|
      t.references :intent, null: false, index: false,
                            foreign_key: { to_table: :decidim_bih_messaging_intents, on_delete: :cascade }
      t.string :channel_group, null: false
      t.string :channel, null: false
      # Which version of a destination this leg addressed (a device endpoint id,
      # an address version). Never the destination itself.
      t.string :destination_version
      t.string :status, null: false, default: "queued"
      t.string :reason
      t.string :provider_message_id
      t.datetime :claimed_at
      t.datetime :settled_at
      t.timestamps
    end
    add_index :decidim_bih_messaging_attempts, [:intent_id, :channel_group, :channel],
              name: :idx_bih_messaging_attempts_group
    add_index :decidim_bih_messaging_attempts, :provider_message_id, name: :idx_bih_messaging_attempts_provider
  end

  private

  def sql_in_list(values)
    values.map { |value| "'#{value}'" }.join(", ")
  end
end
