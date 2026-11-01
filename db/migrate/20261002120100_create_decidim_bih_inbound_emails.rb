# frozen_string_literal: true

class CreateDecidimBihInboundEmails < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_inbound_emails do |t|
      t.references :decidim_organization, null: false, foreign_key: true
      t.string :account, :folder, :gm_msgid, null: false
      t.bigint :uidvalidity, :uid, null: false
      t.string :gm_thrid, :message_id, :in_reply_to, :from_digest, :from_domain, :content_digest
      t.text :labels, :references, :file_numbers, array: true, default: [], null: false
      t.boolean :message_id_conflict, :no_auto_response, :history_only, null: false, default: false
      t.jsonb :authentication, default: {}, null: false
      t.integer :size_bytes, null: false
      t.text :subject_ciphertext, :body_text_ciphertext, :raw_ciphertext
      t.string :classification, :review_reason, :history_reason
      t.string :state, null: false, default: "stored"
      t.integer :processing_attempts, null: false, default: 0
      t.datetime :locked_at, :processed_at, :data_redacted_at
      t.datetime :internal_date, null: false
      t.references :dismissed_by, foreign_key: { to_table: :decidim_users }
      t.timestamps
    end
    add_index :decidim_bih_inbound_emails, [:decidim_organization_id, :account, :gm_msgid], unique: true, name: "idx_bih_inbound_emails_provider_identity"
    add_index :decidim_bih_inbound_emails, [:account, :folder, :uidvalidity, :uid], unique: true, name: "idx_bih_inbound_emails_uid"
    add_index :decidim_bih_inbound_emails, [:decidim_organization_id, :message_id], name: "idx_bih_inbound_emails_message_id"
    add_index :decidim_bih_inbound_emails, [:state, :locked_at]
    add_index :decidim_bih_inbound_emails, :gm_thrid
    create_table :decidim_bih_inbound_email_links do |t|
      t.references :inbound_email, null: false, foreign_key: { to_table: :decidim_bih_inbound_emails }
      t.references :decidim_bih_report, null: false, foreign_key: true
      t.string :association, :assurance, null: false
      t.references :capability, foreign_key: { to_table: :decidim_bih_report_reply_capabilities }
      t.references :created_by, foreign_key: { to_table: :decidim_users }
      t.timestamps
    end
    add_index :decidim_bih_inbound_email_links, [:inbound_email_id, :decidim_bih_report_id], unique: true, name: "idx_bih_inbound_links_report"
    create_table :decidim_bih_mailbox_cursors do |t|
      t.references :decidim_organization, null: false, foreign_key: true
      t.string :account, :folder, null: false
      t.bigint :uidvalidity, :last_uid, null: false, default: 0
      t.datetime :activation_at, :last_polled_at, :last_success_at
      t.string :last_error_class
      t.integer :consecutive_failures, null: false, default: 0
      t.timestamps
    end
    add_index :decidim_bih_mailbox_cursors, [:decidim_organization_id, :account], unique: true, name: "idx_bih_mailbox_cursors_account"
    create_table :decidim_bih_report_service_senders do |t|
      t.references :decidim_organization, null: false, foreign_key: true, index: { name: "idx_report_service_senders_decidim_organiz_200b1b" }
      t.string :email_digest, :label, null: false
      t.text :email_ciphertext, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :decidim_bih_report_service_senders, [:decidim_organization_id, :email_digest], unique: true, name: "idx_bih_service_senders_email"
    create_table :decidim_bih_inbound_email_effects do |t|
      t.references :inbound_email, null: false, foreign_key: { to_table: :decidim_bih_inbound_emails }
      t.references :decidim_bih_report, null: false, foreign_key: true, index: { name: "idx_inbound_email_effects_decidim_bih_rep_1edb82" }
      t.string :effect, null: false
      t.timestamps
    end
    add_index :decidim_bih_inbound_email_effects, [:inbound_email_id, :decidim_bih_report_id, :effect], unique: true, name: "idx_bih_inbound_effect_identity"
  end
end
