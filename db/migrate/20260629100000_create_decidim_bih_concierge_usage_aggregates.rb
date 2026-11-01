# frozen_string_literal: true

# Stores daily aggregate MI bot usage counters only. No raw citizen prompts,
# bot replies, session digests, sender ids, IP addresses, user agents or tokens
# belong in this table.
class CreateDecidimBihConciergeUsageAggregates < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_concierge_usage_aggregates do |t|
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_concierge_usage_org" }
      t.date :bucket_on, null: false
      t.string :channel, null: false
      t.string :outcome, null: false
      t.string :answer_intent, null: false, default: "unknown"
      t.string :locale, null: false, default: "sr"
      t.bigint :requests_count, null: false, default: 0
      t.bigint :message_length_total, null: false, default: 0
      t.bigint :reply_length_total, null: false, default: 0
      t.bigint :quick_replies_total, null: false, default: 0
      t.bigint :sticker_count, null: false, default: 0
      t.timestamps
    end

    add_index :decidim_bih_concierge_usage_aggregates,
              [:decidim_organization_id, :bucket_on, :channel, :outcome, :answer_intent, :locale],
              unique: true,
              name: "idx_bih_concierge_usage_unique"
    add_index :decidim_bih_concierge_usage_aggregates,
              [:decidim_organization_id, :bucket_on],
              name: "idx_bih_concierge_usage_org_day"
    add_check_constraint :decidim_bih_concierge_usage_aggregates,
                         "requests_count >= 0 AND message_length_total >= 0 AND " \
                         "reply_length_total >= 0 AND quick_replies_total >= 0 AND sticker_count >= 0",
                         name: "chk_bih_concierge_usage_counts"
  end
end
