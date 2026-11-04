# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class DecidimBihMigrationsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  MIGRATIONS_ROOT = File.join(ROOT, "db/migrate")
  MIGRATION_NAME_PATTERN = /\A\d{14}_[a-z0-9_]+\.rb\z/

  CORE_TABLES = %w(
    decidim_bih_reports
    decidim_bih_viber_linkages
    decidim_bih_goodwill_accounts
    decidim_bih_goodwill_transactions
    decidim_bih_goodwill_entries
    decidim_bih_goodwill_referrals
    decidim_bih_volunteer_opportunities
    decidim_bih_volunteer_logs
    decidim_bih_volunteer_availabilities
    decidim_bih_goodwill_match_requests
    decidim_bih_goodwill_reward_fulfillments
    decidim_bih_login_tokens
    decidim_bih_local_areas
    decidim_bih_citizen_profiles
    decidim_bih_broadcasts
    decidim_bih_komsiluk_posts
    decidim_bih_komsiluk_post_flags
    decidim_bih_goodwill_rewards
    decidim_bih_settings
    decidim_bih_volunteer_signups
    decidim_bih_volunteer_attendances
    decidim_bih_privacy_retention_runs
    decidim_bih_concierge_feedbacks
    decidim_bih_concierge_usage_aggregates
    decidim_bih_report_events
    decidim_bih_goodwill_reward_fulfillment_events
    decidim_bih_operator_roles
    decidim_bih_operator_audit_events
    decidim_bih_governance_approval_attestations
    decidim_bih_governance_approvals
    decidim_bih_partner_profiles
    decidim_bih_partner_memberships
    decidim_bih_operator_messages
    decidim_bih_partner_notices
    decidim_bih_partner_project_submissions
    decidim_bih_project_donation_links
    decidim_bih_contribution_needs
    decidim_bih_contribution_offers
    decidim_bih_viber_inbound_deliveries
  ).freeze

  def test_migration_filenames_are_timestamped_unique_and_sorted
    names = migration_paths.map { |path| File.basename(path) }
    timestamps = names.map { |name| name.split("_", 2).first }

    assert(names.all? { |name| name.match?(MIGRATION_NAME_PATTERN) })
    assert_equal timestamps.uniq, timestamps
    assert_equal names, names.sort
  end

  def test_migration_classes_match_filenames_and_rails_version
    migration_paths.each do |path|
      filename = File.basename(path)
      expected_class_name = filename.delete_suffix(".rb").split("_")[1..].map(&:capitalize).join
      content = File.read(path)
      migration_class_lines = content.scan(/^class\s+\w+\s+<\s+ActiveRecord::Migration\[(?:7\.2|8\.1)\]$/)

      assert_equal 1, migration_class_lines.size, "#{filename} must declare exactly one supported Rails migration class"
      assert_match(/class #{Regexp.escape(expected_class_name)} < ActiveRecord::Migration\[(?:7\.2|8\.1)\]/, content)
    end
  end

  def test_all_engine_migrations_are_packaged_in_the_gem
    expected_files = migration_paths.map { |path| path.delete_prefix("#{ROOT}/") }
    packaged_migrations = gemspec.files.grep(%r{\Adb/migrate/\d{14}_[a-z0-9_]+\.rb\z})

    assert_equal expected_files, packaged_migrations
    migration_paths.each do |path|
      relative_path = path.delete_prefix("#{ROOT}/")

      assert_includes gemspec.files, relative_path
    end
  end

  def test_core_tables_have_create_migrations
    contents = all_migration_contents

    CORE_TABLES.each do |table|
      assert_includes contents, "create_table :#{table}"
    end
  end

  def test_identity_and_idempotency_indexes_are_declared
    assert_migration_includes(
      "20260925120000_review_volunteer_applications_and_date_attendance.rb",
      'to: "pending"',
      "bih_volunteer_signup_review_allocation_valid",
      "bih_volunteer_signup_queue_time_valid",
      "bih_volunteer_signup_end_time_valid",
      "idx_bih_attendance_day_unique",
      "unique: true"
    )
    assert_migration_includes(
      "20260607182536_create_decidim_bih_reports.rb",
      "[:decidim_organization_id, :reference]",
      "unique: true"
    )
    assert_migration_includes(
      "20260618130000_add_status_token_to_decidim_bih_reports.rb",
      ":status_token",
      "idx_bih_reports_org_status_token",
      "unique: true"
    )
    assert_migration_includes(
      "20260607190000_create_decidim_bih_viber_linkages.rb",
      "[:decidim_organization_id, :viber_sender]",
      "unique: true"
    )
    assert_migration_includes(
      "20260608120000_create_decidim_bih_goodwill_accounts.rb",
      "idx_bih_goodwill_accounts_on_org_and_owner",
      "idx_bih_goodwill_accounts_one_system_per_org",
      "where: \"kind = 'system'\""
    )
    assert_migration_includes(
      "20260608120100_create_decidim_bih_goodwill_transactions.rb",
      "idx_bih_goodwill_txns_on_org_and_idemkey",
      "where: \"idempotency_key IS NOT NULL\""
    )
    assert_migration_includes(
      "20260609133100_create_decidim_bih_volunteer_availabilities.rb",
      "idx_bih_volunteer_avails_on_org_and_user",
      "unique: true"
    )
    assert_migration_includes(
      "20260615120000_create_decidim_bih_goodwill_rewards.rb",
      "idx_bih_goodwill_rewards_org_key",
      "unique: true"
    )
    assert_migration_includes(
      "20260615130000_create_decidim_bih_settings.rb",
      "idx_bih_settings_org_ns_key",
      "unique: true"
    )
    assert_migration_includes(
      "20260616120000_create_decidim_bih_volunteer_signups.rb",
      "idx_bih_volunteer_signups_on_opportunity_and_user",
      "unique: true"
    )
    assert_migration_includes(
      "20260617214500_create_decidim_bih_concierge_feedbacks.rb",
      "idx_bih_concierge_feedbacks_once",
      "unique: true"
    )
    assert_migration_includes(
      "20260629100000_create_decidim_bih_concierge_usage_aggregates.rb",
      "idx_bih_concierge_usage_unique",
      "unique: true"
    )
    assert_migration_includes(
      "20260704100000_create_decidim_bih_operator_roles.rb",
      "idx_bih_operator_roles_org_user_role",
      "idx_bih_operator_roles_org_role_expiry"
    )
    assert_migration_includes(
      "20260704102000_create_decidim_bih_partner_profiles.rb",
      "idx_bih_partner_profiles_org_slug",
      "unique: true",
      "idx_bih_partner_profiles_legacy_group"
    )
    assert_migration_includes(
      "20260704103000_create_decidim_bih_partner_memberships.rb",
      "idx_bih_partner_members_profile_user",
      "unique: true"
    )
    assert_migration_includes(
      "20260809100000_create_decidim_bih_partner_project_submissions.rb",
      "idx_bih_project_submissions_project",
      "unique: true"
    )
    assert_migration_includes(
      "20260809100100_create_decidim_bih_project_donation_links.rb",
      "idx_bih_project_donation_links_project",
      "idx_bih_project_donation_links_campaign",
      "unique: true"
    )
    assert_migration_includes(
      "20260809100300_create_decidim_bih_contribution_offers.rb",
      "idx_bih_contribution_offers_active_user",
      "idx_bih_contribution_offers_active_profile",
      "unique: true"
    )
    assert_migration_includes(
      "20260811110000_add_channel_to_decidim_bih_viber_inbound_deliveries.rb",
      "[:decidim_organization_id, :channel, :provider_message_key]",
      "idx_bih_viber_inbound_org_message",
      "unique: true"
    )
    assert_migration_includes(
      "20260812101100_add_sender_order_index_to_inbound_deliveries.rb",
      "decidim_organization_id channel sender_digest received_at id",
      "idx_bih_inbound_sender_order",
      "algorithm: :concurrently",
      "existing&.valid?",
      "remove_index TABLE_NAME"
    )
    refute_includes migration_content("20260812101100_add_sender_order_index_to_inbound_deliveries.rb"),
                    "if_not_exists: true"
    assert_migration_includes(
      "20260812101000_add_effect_phase_to_inbound_deliveries.rb",
      ":phase",
      ":encrypted_effects",
      ":effects_cursor",
      ":effects_count",
      "SET phase = 'complete'",
      "WHERE state = 'processed'",
      "chk_bih_inbound_delivery_phase",
      "chk_bih_inbound_effect_cursor"
    )
    assert_migration_includes(
      "20260812101200_add_effect_scrub_deadline_to_inbound_deliveries.rb",
      ":next_effect_scrub_at",
      "idx_bih_inbound_effect_scrub",
      "phase next_effect_scrub_at",
      "algorithm: :concurrently",
      "existing&.valid?"
    )
  end

  def test_privacy_and_audit_migrations_bound_raw_content_storage
    assert_migration_includes(
      "20260617214500_create_decidim_bih_concierge_feedbacks.rb",
      "raw citizen messages",
      "t.string :reply_id",
      "t.string :session_digest",
      "t.jsonb :metadata"
    )
    assert_migration_excludes(
      "20260617214500_create_decidim_bih_concierge_feedbacks.rb",
      :user_message,
      :reply_text,
      :ip_address,
      :user_agent
    )
    assert_migration_includes(
      "20260630143000_add_review_transcript_to_decidim_bih_concierge_feedbacks.rb",
      "clicks helpful/not",
      "add_column :decidim_bih_concierge_feedbacks, :citizen_message, :text",
      "add_column :decidim_bih_concierge_feedbacks, :bot_reply_text, :text"
    )
    assert_migration_excludes(
      "20260630143000_add_review_transcript_to_decidim_bih_concierge_feedbacks.rb",
      :decidim_user_id,
      :ip_address,
      :user_agent,
      :feedback_token
    )
    assert_migration_includes(
      "20260630143100_anonymize_decidim_bih_concierge_feedback_users.rb",
      "decidim_user_id = NULL",
      "Intentionally irreversible"
    )

    assert_migration_includes(
      "20260629100000_create_decidim_bih_concierge_usage_aggregates.rb",
      "daily aggregate MI bot usage counters",
      "t.bigint :requests_count",
      "t.bigint :reply_length_total"
    )
    assert_migration_excludes(
      "20260629100000_create_decidim_bih_concierge_usage_aggregates.rb",
      :user_message,
      :reply_text,
      :reply_id,
      :session_digest,
      :viber_sender,
      :ip_address,
      :user_agent
    )

    assert_migration_includes(
      "20260617223000_create_decidim_bih_report_events.rb",
      "Append-only, PII-minimized audit events",
      "t.string :event_type",
      "t.string :source",
      "t.string :actor_role",
      "t.jsonb :metadata"
    )
    assert_migration_excludes(
      "20260617223000_create_decidim_bih_report_events.rb",
      :reporter_email,
      :reporter_phone,
      :description,
      :address,
      :internal_note
    )

    assert_migration_includes(
      "20260617234500_create_decidim_bih_reward_fulfillment_events.rb",
      "t.string :event_type",
      "t.string :source",
      "t.string :actor_role",
      "t.jsonb :metadata"
    )
    assert_migration_includes(
      "20260704101000_create_decidim_bih_operator_audit_events.rb",
      "Append-only, PII-minimized audit events",
      "t.string :permission",
      "t.string :resource_type",
      "t.jsonb :metadata"
    )
    assert_migration_excludes(
      "20260704101000_create_decidim_bih_operator_audit_events.rb",
      :body,
      :description,
      :phone,
      :email,
      :viber_sender
    )
    assert_migration_includes(
      "20260709190000_create_decidim_bih_governance_approvals.rb",
      "Append-only, PII-minimized approval records",
      "t.string :governance_kind",
      "t.text :evidence_summary",
      "t.string :evidence_digest",
      "t.jsonb :metadata"
    )
    assert_migration_excludes(
      "20260709190000_create_decidim_bih_governance_approvals.rb",
      :command_output,
      :raw_log,
      :token,
      :password,
      :provider_payload,
      :backup_path
    )
    assert_migration_includes(
      "20260812100000_create_decidim_bih_governance_approval_attestations.rb",
      "Append-only proof of independent release approval",
      "t.string :approval_role",
      "t.datetime :attested_at",
      "idx_bih_release_attestations_approval",
      "unique: true"
    )
    assert_migration_excludes(
      "20260812100000_create_decidim_bih_governance_approval_attestations.rb",
      :evidence_summary,
      :command_output,
      :raw_log,
      :token,
      :provider_payload
    )
    assert_migration_includes(
      "20260704104000_create_decidim_bih_operator_messages.rb",
      "Decidim notification messages",
      "t.string :subject",
      "t.text :body",
      "t.string :context_type"
    )
    assert_migration_includes(
      "20260704105000_create_decidim_bih_partner_notices.rb",
      "Public notices published by verified organizations",
      "t.string :notice_type",
      "t.datetime :published_at",
      "t.datetime :expires_at"
    )
    assert_migration_includes(
      "20260811100000_create_decidim_bih_viber_inbound_deliveries.rb",
      "t.string :provider_message_key",
      "t.string :sender_digest",
      "t.text :encrypted_payload",
      "t.datetime :expires_at",
      "idx_bih_viber_inbound_org_message",
      "unique: true"
    )
    assert_migration_excludes(
      "20260811100000_create_decidim_bih_viber_inbound_deliveries.rb",
      :raw_provider_message_id,
      :sender,
      :message_text,
      :error_message,
      :webhook_payload
    )
    assert_migration_includes(
      "20260811110000_add_channel_to_decidim_bih_viber_inbound_deliveries.rb",
      ":channel",
      "default: \"viber\"",
      "[:decidim_organization_id, :channel, :provider_message_key]"
    )
    assert_migration_excludes(
      "20260812101000_add_effect_phase_to_inbound_deliveries.rb",
      :raw_provider_message_id,
      :sender,
      :message_text,
      :error_message,
      :webhook_payload
    )
    assert_migration_excludes(
      "20260812101200_add_effect_scrub_deadline_to_inbound_deliveries.rb",
      :raw_provider_message_id,
      :sender,
      :message_text,
      :error_message,
      :webhook_payload
    )
  end

  def test_privacy_audit_contract_covers_durable_audit_tables
    contract_tables = Decidim::Bih.required_audit_event_streams.filter_map do |stream|
      storage = stream.fetch(:storage)
      storage.delete_prefix("table:") if storage.start_with?("table:")
    end

    %w(
      decidim_bih_broadcasts
      decidim_bih_concierge_feedbacks
      decidim_bih_concierge_usage_aggregates
      decidim_bih_goodwill_match_requests
      decidim_bih_goodwill_reward_fulfillment_events
      decidim_bih_goodwill_transactions
      decidim_bih_governance_approval_attestations
      decidim_bih_governance_approvals
      decidim_bih_operator_audit_events
      decidim_bih_operator_messages
      decidim_bih_partner_notices
      decidim_bih_partner_profiles
      decidim_bih_privacy_retention_runs
      decidim_bih_report_events
      decidim_bih_reports
      decidim_bih_viber_inbound_deliveries
    ).each do |table|
      assert_includes contract_tables, table
      assert_includes all_migration_contents, "create_table :#{table}"
    end
  end

  def test_operator_history_indexes_are_declared
    assert_migration_includes(
      "20260617203000_create_decidim_bih_privacy_retention_runs.rb",
      "idx_bih_privacy_retention_runs_org_started",
      "idx_bih_privacy_retention_runs_org_status_started"
    )
    assert_migration_includes(
      "20260617223000_create_decidim_bih_report_events.rb",
      "idx_bih_report_events_report_occurred",
      "idx_bih_report_events_org_type_occurred"
    )
    assert_migration_includes(
      "20260617234500_create_decidim_bih_reward_fulfillment_events.rb",
      "idx_bih_reward_events_fulfillment_time",
      "idx_bih_reward_events_org_type_time"
    )
    assert_migration_includes(
      "20260704101000_create_decidim_bih_operator_audit_events.rb",
      "idx_bih_operator_audit_org_time",
      "idx_bih_operator_audit_org_type_time",
      "idx_bih_operator_audit_resource_time"
    )
    assert_migration_includes(
      "20260709190000_create_decidim_bih_governance_approvals.rb",
      "idx_bih_governance_approvals_org_kind_time",
      "idx_bih_governance_approvals_org_status_time"
    )
    assert_migration_includes(
      "20260812100000_create_decidim_bih_governance_approval_attestations.rb",
      "idx_bih_release_attestations_approval",
      "idx_bih_release_attestations_audit",
      "idx_bih_release_attestations_org_time"
    )
    assert_migration_includes(
      "20260704104000_create_decidim_bih_operator_messages.rb",
      "idx_bih_operator_messages_org_sent",
      "idx_bih_operator_messages_context_sent"
    )
    assert_migration_includes(
      "20260704105000_create_decidim_bih_partner_notices.rb",
      "idx_bih_partner_notices_org_published",
      "idx_bih_partner_notices_profile_published"
    )
  end

  def test_explicit_database_object_names_fit_postgresql_limit
    all_migration_contents.scan(/name:\s+"((?:idx|fk|chk)_[^"]+)"/).flatten.each do |name|
      assert name.bytesize <= 63, "#{name} exceeds PostgreSQL's 63-byte identifier limit"
    end
  end

  def test_concurrent_index_migrations_are_transaction_safe_and_idempotent
    migration_paths.each do |path|
      content = File.read(path)
      next unless content.include?("algorithm: :concurrently")

      assert_includes content, "disable_ddl_transaction!", File.basename(path)
      assert_concurrent_index_calls_are_idempotent(path, content)
    end
  end

  private

  def gemspec
    @gemspec ||= Gem::Specification.load(File.join(ROOT, "decidim-bih.gemspec"))
  end

  def migration_paths
    @migration_paths ||= Dir[File.join(MIGRATIONS_ROOT, "*.rb")]
  end

  def migration_content(name)
    File.read(File.join(MIGRATIONS_ROOT, name))
  end

  def all_migration_contents
    migration_paths.map { |path| File.read(path) }.join("\n")
  end

  def assert_migration_includes(name, *snippets)
    content = migration_content(name)

    snippets.each do |snippet|
      assert_includes content, snippet
    end
  end

  def assert_migration_excludes(name, *snippets)
    content = migration_content(name)

    snippets.each do |column_name|
      assert content !~ /t\.\w+\s+:#{Regexp.escape(column_name.to_s)}\b/
    end
  end

  def assert_concurrent_index_calls_are_idempotent(path, content)
    filename = File.basename(path)
    repairs_invalid_named_index = repairs_invalid_named_index?(content)

    content.split(/^\s*add_index\s+/).drop(1).each do |statement|
      next unless concurrent_index_statement?(statement)
      next if repairs_invalid_named_index

      assert_includes statement, "if_not_exists: true", filename
    end

    content.split(/^\s*remove_index\s+/).drop(1).each do |statement|
      next unless concurrent_index_statement?(statement)
      next if repairs_invalid_named_index && statement.include?("if existing")

      assert_includes statement, "if_exists: true", filename
    end
  end

  def repairs_invalid_named_index?(content)
    [
      "existing = connection.indexes",
      "return if existing&.valid?",
      "remove_index TABLE_NAME",
      "if existing"
    ].all? { |snippet| content.include?(snippet) }
  end

  def concurrent_index_statement?(statement)
    statement.include?("algorithm: :concurrently")
  end
end
