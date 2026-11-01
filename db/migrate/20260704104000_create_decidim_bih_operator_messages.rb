# frozen_string_literal: true

# Operator-to-user Decidim notification messages.
#
# V1 delivery is Decidim in-app notifications only. The message body is stored
# because the recipient must be able to read it later; audit rows must reference
# this record without copying the body into generic metadata.
class CreateDecidimBihOperatorMessages < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_operator_messages do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :sender,
                   null: true,
                   index: { name: "idx_bih_operator_messages_sender" },
                   foreign_key: { to_table: :decidim_users }
      t.references :recipient,
                   null: false,
                   index: { name: "idx_bih_operator_messages_recipient" },
                   foreign_key: { to_table: :decidim_users }
      t.string :subject, null: false
      t.text :body, null: false
      t.string :context_type
      t.bigint :context_id
      t.datetime :sent_at, null: false
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :decidim_bih_operator_messages,
              [:decidim_organization_id, :sent_at, :id],
              name: "idx_bih_operator_messages_org_sent"
    add_index :decidim_bih_operator_messages,
              [:context_type, :context_id, :sent_at],
              name: "idx_bih_operator_messages_context_sent"
  end
end
