# frozen_string_literal: true

# Task 3.1 of the communication consolidation plan.
#
# The attempts table already exists (Phase 1,
# 20260914140000_create_decidim_bih_messaging_storage.rb). What it could not do
# was answer three questions Phase 3 has to answer:
#
#   * WHICH destination did this leg address? Without a normalized, kind-scoped
#     digest an attempt cannot be correlated to a transport suppression, and a
#     deleted account's rows cannot be redacted by destination either.
#   * WHICH provider ids belong to this leg? One `single` phone request carries
#     the whole channel list, and Infobip answers with one id PER CHANNEL. A
#     single `provider_message_id` silently drops every id after the first, so a
#     delivery report for the WhatsApp leg could never be matched back.
#   * WHEN was it accepted, as distinct from when it resolved? `settled_at` is
#     overwritten by every settle, so once a delivery report lands there is no
#     record left of the acceptance that preceded it.
#
# Deliberately additive and nullable: existing rows keep their meaning, and no
# historical row is given a destination, an id or a timestamp it never had.
# There is no backfill here, and none anywhere in this phase.
class AddMessagingAttemptCorrelation < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_messaging_attempts, :destination_kind, :string
    # SHA256 of the kind-scoped normalized destination. NEVER the raw value.
    add_column :decidim_bih_messaging_attempts, :destination_digest, :string
    add_column :decidim_bih_messaging_attempts, :provider_message_ids, :string,
               array: true, null: false, default: []
    add_column :decidim_bih_messaging_attempts, :accepted_at, :datetime
    add_column :decidim_bih_messaging_attempts, :resolved_at, :datetime

    add_index :decidim_bih_messaging_attempts, [:destination_kind, :destination_digest],
              name: :idx_bih_messaging_attempts_destination
    # A delivery report arrives with one provider id and has to find its leg.
    add_index :decidim_bih_messaging_attempts, :provider_message_ids,
              using: :gin, name: :idx_bih_messaging_attempts_provider_ids

    # Late and duplicate provider events are the normal case, not the exception.
    # `occurred_at` is the PROVIDER's clock, `event_ref` its own id: together
    # they make ingestion idempotent and make an event older than a
    # reactivation recordable without letting it re-suppress.
    add_column :decidim_bih_messaging_suppressions, :occurred_at, :datetime
    add_column :decidim_bih_messaging_suppressions, :event_ref, :string
    add_index :decidim_bih_messaging_suppressions,
              [:decidim_organization_id, :provider, :event_ref],
              unique: true, name: :idx_bih_messaging_suppressions_event
  end
end
