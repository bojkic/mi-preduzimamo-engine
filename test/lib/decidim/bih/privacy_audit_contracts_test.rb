# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class PrivacyAuditContractsTest < Minitest::Test
  CITY_SERVICE_WORKFLOW_STORAGE = "tables:decidim_app_city_service_incidents+decidim_app_city_service_projections+" \
                                  "decidim_app_city_service_duplicate_decisions+decidim_app_city_service_effects+" \
                                  "decidim_app_city_service_coverages+decidim_app_city_service_automation_decisions"

  EXPECTED_STREAM_IDS = %w(
    admin_analytics_exports
    city_content_overrides
    city_service_events
    city_service_incident_workflow
    community_contribution_workflows
    concierge_feedback
    concierge_metric_rollups
    concierge_usage_aggregates
    external_chat_conversation_cache
    external_chat_reply_queue
    goodwill_match_requests
    goodwill_transactions
    governance_approval_attestations
    governance_approvals
    homepage_public_activity
    integration_health
    komsiluk_broadcasts
    komsiluk_naming_campaign_report
    komsiluk_notice_publication
    komsiluk_phone_intents
    komsiluk_post_reviews
    milica_answer_outcome_aggregates
    milica_conversation_location
    milica_dimensioned_answer_counters
    milica_model_usage_reservations
    milica_prepared_public_sources
    milica_public_place_suggestions
    milica_read_timing_aggregates
    notification_topic_preferences
    operator_audit_events
    operator_messages
    partner_impact_summary
    partner_notices
    partner_profiles
    phone_auth_message_queue
    platform_delivery_receipts
    privacy_retention_runs
    public_impact_summary
    report_dispatch_private_content
    report_events
    report_photo_draft_storage
    report_push_claim_state
    report_review_private_drafts
    report_review_private_proposals
    report_runtime_state
    reward_fulfillment_events
    viber_inbound_deliveries
    viber_reply_queue
    viber_session_state_cache
    volunteer_attendance
  ).freeze

  EXPECTED_BUCKET_IDS = %w(
    account_notifications
    channel_connection_challenges channel_connections
    chat_feedback
    citizen_phones
    community_review_reasons
    komsiluk_delivery_data
    komsiluk_post_bodies
    login_tokens
    messaging_attempts
    messaging_suppressions
    operator_message_bodies
    partner_private_contacts
    partner_verification_documents
    pending_registrations
    report_contacts
    report_coordinates
    report_dispatch_contents
    report_evidence_shares
    report_mail_linked
    report_mail_unlinked
    report_photo_drafts
    report_photos
    report_review_drafts
    report_review_proposals
    viber_business_contacts
    viber_linkages
    volunteer_availabilities
  ).freeze

  EXPECTED_STREAM_STORAGE = %w(
    cache:milica/public-place
    derived_csv:Decidim::Bih::Admin::AnalyticsSummary
    derived_json:DecidimApp::Bijeljina::KomsilukNamingCampaignMetrics
    derived_view:Decidim::Bih::HomepageActivity
    derived_view:Decidim::Bih::ImpactSummary
    redis:bih:integration_health
    redis:milica/read-metrics/v1
    redis:milica/answer-metrics/v1
    redis:milica/answer-dimensions/v1
    redis:decidim-bih:milica:model-led:usage:v1
    redis:decidim-bih:milica:dialogue:v1/<organization>/<actor>/<conversation>
    table:city_service_source_snapshots
    redis:decidim-bih/external-chat/conversation/<organization>/<channel>/<hmac>
    active_job:integrations:encrypted_payload
    table:decidim_app_city_service_events
    table:decidim_bih_platform_deliveries
    tables:decidim_bih_partner_project_submissions+decidim_bih_project_donation_links+decidim_bih_contribution_needs+decidim_bih_contribution_offers
    table:decidim_bih_broadcasts
    tables:decidim_bih_komsiluk_posts+decidim_bih_komsiluk_post_revisions+decidim_bih_komsiluk_help_responses+decidim_bih_komsiluk_photo_drafts
    tables:decidim_bih_komsiluk_send_intents+decidim_bih_komsiluk_phone_deliveries+decidim_bih_komsiluk_sms_budgets
    table:decidim_bih_komsiluk_post_reviews
    table:decidim_bih_concierge_feedbacks
    table:decidim_bih_concierge_metric_rollups
    table:decidim_app_city_service_entries+decidim_app_foundation_status_overrides
    table:decidim_bih_concierge_usage_aggregates
    table:decidim_bih_goodwill_match_requests
    table:decidim_bih_goodwill_reward_fulfillment_events
    table:decidim_bih_goodwill_transactions
    table:decidim_bih_governance_approval_attestations
    table:decidim_bih_governance_approvals
    tables:decidim_bih_messaging_preferences+decidim_bih_messaging_preference_changes
    table:decidim_bih_operator_audit_events
    table:decidim_bih_operator_messages
    table:decidim_bih_partner_notices
    table:decidim_bih_partner_profiles
    table:decidim_bih_privacy_retention_runs
    table:decidim_bih_reports
    table:decidim_bih_report_events
    table:decidim_bih_report_dispatches
    table:decidim_bih_report_review_proposals
    table:decidim_bih_reports.review_draft
    table:decidim_bih_report_photo_drafts+active_storage
    table:decidim_notifications.extra
    table:decidim_bih_viber_inbound_deliveries
    active_job:integrations:viber_encrypted_payload
    active_job:integrations:phone_auth_encrypted_payload
    redis:bih:viber:state/<organization>/<hmac>
    tables:decidim_bih_volunteer_signups+decidim_bih_volunteer_attendances
    derived_view:Decidim::Bih::PartnerImpactSummary
  ).push(CITY_SERVICE_WORKFLOW_STORAGE).freeze

  EXPECTED_COMMUNITY_CONTRIBUTION_FIELDS = %w(
    accepted_at accepted_by_id active address budget_amount campaign_key closed_at confirmed_at
    confirmed_by_id contribution_need_id created_at decidim_author_id decidim_budgets_project_id
    decidim_organization_id decidim_user_id decline_reason declined_at declined_by_id delivered_at
    description ends_on fulfillment_status location lock_version needed_by need_type partner_profile_id
    published_at quantity recognized_at recognized_by_id rejection_reason review_status reviewed_at
    reviewed_by_id starts_on status submitted_at title unit updated_at withdrawn_at
  ).freeze

  def test_audit_streams_are_unique_sorted_and_cover_current_event_surfaces
    streams = Decidim::Bih.required_audit_event_streams
    ids = streams.map { |stream| stream.fetch(:id) }
    storage = streams.map { |stream| stream.fetch(:storage) }

    assert_equal ids.uniq, ids
    assert_equal ids.sort, ids
    assert_equal EXPECTED_STREAM_IDS, ids
    assert_equal EXPECTED_STREAM_STORAGE.sort, storage.sort
  end

  def test_model_usage_stream_is_host_owned_expiring_aggregate_without_conversation_identity
    stream = contract("milica_model_usage_reservations")

    assert_equal "host", stream.fetch(:owner)
    assert_equal "DecidimApp::Bijeljina::Milica::ConversationUsage", stream.fetch(:producer)
    assert_equal "redis:decidim-bih:milica:model-led:usage:v1", stream.fetch(:storage)
    assert_equal %w(committed_micro_usd reserved_calls settled_micro_usd settled_calls input_tokens output_tokens), stream.fetch(:stored_fields)
    assert_equal %w(organization_id day phase input_tokens output_tokens cost_micro_usd), stream.fetch(:allowed_metadata)
    assert_equal %w(organization_day_key redis_ttl_48_hours atomic_reserve_before_dispatch two_call_limit), stream.fetch(:enforcement)
    assert_includes stream.fetch(:stores), "expires after 48 hours"
    assert_includes stream.fetch(:privacy_boundary), "Unknown usage keeps its reservation"
    assert_includes stream.fetch(:tests), "test/contracts/milica_conversation_usage_test.rb"
    excluded = %w(raw_citizen_message bot_reply_text actor_id conversation_key session_digest address location provider_payload phone email)
    assert_equal excluded, stream.fetch(:excluded_pii)
    assert_empty (stream.fetch(:stored_fields) + stream.fetch(:allowed_metadata)) & excluded
  end

  def test_platform_receipt_contract_distinguishes_expiry_from_retention_and_forbids_payloads
    stream = contract("platform_delivery_receipts")
    assert_includes stream.fetch(:stored_fields), "decidim_user_id"
    assert_includes stream.fetch(:stored_fields), "acknowledgment_kind"
    assert_includes stream.fetch(:excluded_pii), "receipt_token"
    assert_includes stream.fetch(:excluded_pii), "push_auth"
    assert_includes stream.fetch(:privacy_boundary), "expires_at ends dispatch and signed-token validity"
    assert_includes stream.fetch(:privacy_boundary), "KOMSILUK_DELIVERY_BEFORE retention cutoff"
    assert_includes stream.fetch(:enforcement), "cascade_hard_account_deletion"
    assert_empty stream.fetch(:stored_fields) & stream.fetch(:excluded_pii)
  end

  def test_incident_workflow_contract_keeps_reviewer_attribution_without_recipient_snapshots
    stream = contract("city_service_incident_workflow")
    assert_equal "host", stream.fetch(:owner)
    assert_includes stream.fetch(:stored_fields), "reviewer_id"
    assert_includes stream.fetch(:stored_fields), "previous_memberships"
    assert_includes stream.fetch(:excluded_pii), "user_ids"
    assert_includes stream.fetch(:enforcement), "metadata_only_outbox"
    assert_empty stream.fetch(:stored_fields) & stream.fetch(:excluded_pii)
  end

  def test_topic_preference_contract_separates_history_from_transport_credentials
    stream = contract("notification_topic_preferences")
    assert_includes stream.fetch(:stored_fields), "topic"
    assert_includes stream.fetch(:stored_fields), "historical_channel"
    assert_includes stream.fetch(:excluded_pii), "push_auth"
    assert_includes stream.fetch(:enforcement), "unique_user_topic"
    assert_includes stream.fetch(:enforcement), "no_matrix_json"
  end

  def test_retention_buckets_are_unique_sorted_and_declare_their_actual_executor
    buckets = Decidim::Bih.required_privacy_retention_buckets
    ids = buckets.map { |bucket| bucket.fetch(:id) }
    service_cutoffs = buckets.filter_map { |bucket| bucket[:service_cutoff_key] }
    env_cutoffs = buckets.filter_map { |bucket| bucket[:env_cutoff_key] }

    assert_equal ids.uniq, ids
    assert_equal ids.sort, ids
    assert_equal EXPECTED_BUCKET_IDS, ids
    assert_includes service_cutoffs, "report_contact_before"
    assert_includes service_cutoffs, "chat_feedback_before"
    assert_includes service_cutoffs, "community_review_reason_before"
    assert_includes service_cutoffs, "partner_private_contact_before"
    assert_includes service_cutoffs, "partner_verification_document_before"
    assert_includes service_cutoffs, "operator_message_body_before"
    assert_includes service_cutoffs, "login_token_before"
    assert_includes service_cutoffs, "komsiluk_delivery_before"
    assert_includes env_cutoffs, "KOMSILUK_DELIVERY_BEFORE"
    refute_includes service_cutoffs, "pending_registration_before"
    assert_includes env_cutoffs, "REPORT_CONTACT_BEFORE"
    assert_includes env_cutoffs, "CHAT_FEEDBACK_BEFORE"
    assert_includes env_cutoffs, "COMMUNITY_REVIEW_REASON_BEFORE"
    assert_includes env_cutoffs, "PARTNER_PRIVATE_CONTACT_BEFORE"
    assert_includes env_cutoffs, "PARTNER_VERIFICATION_DOCUMENT_BEFORE"
    assert_includes env_cutoffs, "OPERATOR_MESSAGE_BODY_BEFORE"
    assert_includes env_cutoffs, "LOGIN_TOKEN_BEFORE"
    refute_includes env_cutoffs, "PENDING_REGISTRATION_BEFORE"
    assert(buckets.all? { |bucket| bucket.fetch(:action).include?("_") })
    assert(buckets.all? { |bucket| bucket.fetch(:excludes_from_run_history).any? })
  end

  def test_monthly_sweep_cutoffs_are_accepted_by_the_service_and_exclude_separate_lifecycle
    require_relative "../../../../app/services/decidim/bih/privacy/retention_sweep"
    contracts = Decidim::Bih::PrivacyAuditContracts
    accepted = Decidim::Bih::Privacy::RetentionSweep.instance_method(:initialize).parameters.map(&:last)
    assert_empty contracts.sweep_cutoff_keys - accepted
    refute_includes contracts.sweep_bucket_ids, :pending_registrations
    pending = contracts.retention_buckets.find { |bucket| bucket[:id] == "pending_registrations" }
    assert_equal "Decidim::Bih::Registration::PendingLifecycle", pending.fetch(:lifecycle_service)
    assert_equal 7, pending.fetch(:retention_days)
    photo = contracts.retention_buckets.find { |bucket| bucket[:id] == "report_photo_drafts" }
    assert_equal "Decidim::Bih::ReportPhotoDraft", photo.fetch(:lifecycle_service)
    assert_equal 2, photo.fetch(:retention_hours)
    refute_includes contracts.sweep_bucket_ids, :report_photo_drafts
  end

  def test_audit_stream_rows_are_explicit_and_reviewable
    Decidim::Bih.required_audit_event_streams.each do |stream|
      host_owned = %w(
        city_content_overrides
        city_service_events city_service_incident_workflow external_chat_conversation_cache komsiluk_naming_campaign_report
        milica_answer_outcome_aggregates milica_dimensioned_answer_counters milica_model_usage_reservations
        milica_prepared_public_sources milica_public_place_suggestions milica_read_timing_aggregates
      ).include?(stream.fetch(:id))
      expected_owner = if stream.fetch(:id) == "milica_conversation_location"
                         "engine+host"
                       elsif host_owned
                         "host"
                       else
                         "engine"
                       end
      assert_equal expected_owner, stream.fetch(:owner)
      assert stream.fetch(:producer).to_s.length.positive?
      assert_present_sentence stream.fetch(:stores)
      assert_present_sentence stream.fetch(:privacy_boundary)
      assert_non_empty_array stream.fetch(:consumers)
      assert_non_empty_array stream.fetch(:stored_fields)
      assert_non_empty_array stream.fetch(:excluded_pii)
      assert_non_empty_array stream.fetch(:enforcement)
      assert_non_empty_array stream.fetch(:tests)
      assert(stream.fetch(:tests).all? { |path| path.start_with?("test/", "rails_test/") })
    end
  end

  def test_raw_content_and_contact_exclusions_are_documented
    contacts = %w(phone email address)
    raw_content_markers = %w(description raw_citizen_message bot_reply_text provider_payload recipient_list member_list)

    exclusions = Decidim::Bih
                 .required_audit_event_streams
                 .flat_map { |stream| stream.fetch(:excluded_pii) }

    contacts.each { |marker| assert_includes exclusions, marker }
    raw_content_markers.each { |marker| assert_includes exclusions, marker }
  end

  def test_report_and_reward_sanitizer_forbidden_keys_are_manifested
    report = contract("report_events")
    reward = contract("reward_fulfillment_events")

    assert_includes report.fetch(:forbidden_metadata_keys), "reporter_email"
    assert_includes report.fetch(:forbidden_metadata_keys), "description"
    assert_includes report.fetch(:forbidden_metadata_keys), "payload"
    assert_includes reward.fetch(:forbidden_metadata_keys), "phone"
    assert_includes reward.fetch(:forbidden_metadata_keys), "provider_payload"
    assert_includes reward.fetch(:forbidden_metadata_keys), "pickup_location"
  end

  # case_agent_lease: job_id is an ActiveJob UUID used only to find the lease
  # owner; it is stored, never shown to staff, and identifies no person.
  def test_report_events_manifest_the_case_agent_lease_metadata
    allowed = contract("report_events").fetch(:allowed_metadata)

    %w(proposal_id lease job_id prompt_version).each { |key| assert_includes allowed, key }
  end

  def test_goodwill_contribution_metadata_is_bounded_and_omits_reviewer_identity
    goodwill = contract("goodwill_transactions")
    allowed = goodwill.fetch(:allowed_metadata)

    assert_includes allowed, "contribution_offer_id"
    assert_includes allowed, "contribution_need_id"
    refute_includes allowed, "reviewed_by_id"
  end

  def test_partner_impact_requires_lfbn_recognition_before_public_credit
    impact = contract("partner_impact_summary")

    assert_includes impact.fetch(:enforcement), "recognized_only"
    refute_includes impact.fetch(:enforcement), "confirmed_only"
  end

  def test_community_contribution_manifest_matches_the_logical_union_schema
    workflow = contract("community_contribution_workflows")

    assert_equal EXPECTED_COMMUNITY_CONTRIBUTION_FIELDS.sort, workflow.fetch(:stored_fields).sort
    %w(
      decidim_bih_partner_project_submissions
      decidim_bih_project_donation_links
      decidim_bih_contribution_needs
      decidim_bih_contribution_offers
    ).each do |table|
      assert_includes workflow.fetch(:storage), table
    end
  end

  def test_report_runtime_state_tracks_status_token_as_private_credential
    runtime = contract("report_runtime_state")

    assert_includes runtime.fetch(:stored_fields), "status_token"
    assert_includes runtime.fetch(:excluded_pii), "status_token"
    assert_includes runtime.fetch(:privacy_boundary), "private link credentials"
    assert_includes runtime.fetch(:tests), "test/mailers/decidim/bih/reporter_mailer_test.rb"
  end

  def test_admin_analytics_contract_covers_digest_consumer
    stream = contract("admin_analytics_exports")

    assert_includes stream.fetch(:consumers), "decidim_bih:analytics:digest"
    assert_includes stream.fetch(:enforcement), "digest_sections"
    assert_includes stream.fetch(:enforcement), "no_digest_attachments"
    assert_includes stream.fetch(:excluded_pii), "status_token"
    assert_includes stream.fetch(:excluded_pii), "report_reference"
    assert_includes stream.fetch(:excluded_pii), "csv_attachment"
    assert_includes stream.fetch(:tests), "test/tasks/analytics_digest_test.rb"
  end

  def test_external_chat_cache_is_short_lived_and_excludes_provider_identity
    stream = contract("external_chat_conversation_cache")

    assert_equal "host", stream.fetch(:owner)
    assert_includes stream.fetch(:enforcement), "hmac_identity_key"
    assert_includes stream.fetch(:enforcement), "MAX_TURNS_6"
    assert_includes stream.fetch(:enforcement), "MAX_TONE_HISTORY_10"
    assert_includes stream.fetch(:enforcement), "redis_ttl_30_minutes"
    assert_includes stream.fetch(:excluded_pii), "raw_sender"
    assert_includes stream.fetch(:excluded_pii), "viber_identifier"
    assert_includes stream.fetch(:excluded_pii), "whatsapp_identifier"
    assert_includes stream.fetch(:excluded_pii), "messenger_identifier"
    assert_includes stream.fetch(:excluded_pii), "instagram_identifier"
    assert_includes stream.fetch(:excluded_pii), "provider_contact_name"
    assert_includes stream.fetch(:excluded_pii), "provider_username"
    assert_includes stream.fetch(:excluded_pii), "raw_coordinates"
    assert_includes stream.fetch(:stores), "voluntarily supplied personal data"
    assert_includes stream.fetch(:privacy_boundary), "30 minutes"
    assert_includes stream.fetch(:enforcement), "five_minute_effect_scrub"
    assert_includes stream.fetch(:enforcement), "payload_free_tombstone"
    refute_includes stream.fetch(:excluded_pii), "phone"
    refute_includes stream.fetch(:excluded_pii), "email"
    refute_includes stream.fetch(:excluded_pii), "address"
  end

  def test_external_chat_reply_queue_contains_only_an_expiring_ciphertext
    stream = contract("external_chat_reply_queue")

    assert_equal ["encrypted_payload"], stream.fetch(:stored_fields)
    assert_includes stream.fetch(:enforcement), "ciphertext_only_job_arguments"
    assert_includes stream.fetch(:enforcement), "after_transaction_commit"
    assert_includes stream.fetch(:enforcement), "configured_job_scheduling"
    assert_includes stream.fetch(:enforcement), "serialize_defense"
    assert_includes stream.fetch(:enforcement), "expiry_inside_envelope"
    assert_includes stream.fetch(:enforcement), "session_reply_ttl_23_hours"
    assert_includes stream.fetch(:enforcement), "channel_only_exhaustion_log"
    assert_includes stream.fetch(:enforcement), "allowlisted_provider_error_metadata"
    assert_includes stream.fetch(:allowed_metadata), "http_status"
    assert_includes stream.fetch(:allowed_metadata), "error_code"
    assert_includes stream.fetch(:allowed_metadata), "error_group"
    assert_includes stream.fetch(:excluded_pii), "raw_recipient"
    assert_includes stream.fetch(:excluded_pii), "raw_reply_text"
  end

  def test_viber_reply_queue_contains_only_an_expiring_ciphertext
    stream = contract("viber_reply_queue")

    assert_equal ["encrypted_payload"], stream.fetch(:stored_fields)
    assert_includes stream.fetch(:enforcement), "ciphertext_only_job_arguments"
    assert_includes stream.fetch(:enforcement), "configured_job_scheduling"
    assert_includes stream.fetch(:enforcement), "serialize_defense"
    assert_includes stream.fetch(:enforcement), "expiry_inside_envelope"
    assert_includes stream.fetch(:enforcement), "session_reply_ttl_23_hours"
    assert_includes stream.fetch(:enforcement), "allowlisted_provider_error_metadata"
    assert_includes stream.fetch(:excluded_pii), "raw_recipient"
    assert_includes stream.fetch(:excluded_pii), "raw_reply_text"
    assert_includes stream.fetch(:excluded_pii), "viber_identifier"
  end

  def test_viber_inbound_receipt_covers_bounded_fenced_durable_effects
    stream = contract("viber_inbound_deliveries")

    assert_includes stream.fetch(:stored_fields), "encrypted_effects"
    assert_includes stream.fetch(:stored_fields), "phase"
    assert_includes stream.fetch(:stored_fields), "effects_cursor"
    assert_includes stream.fetch(:stored_fields), "effects_count"
    assert_includes stream.fetch(:stored_fields), "next_effect_scrub_at"
    assert_includes stream.fetch(:enforcement), "allowlisted_durable_effects"
    assert_includes stream.fetch(:enforcement), "claim_generation_fence"
    assert_includes stream.fetch(:enforcement), "exact_cursor_compare_and_set"
    assert_includes stream.fetch(:enforcement), "per_effect_deadline"
    assert_includes stream.fetch(:enforcement), "five_minute_effect_scrub"
    assert_includes stream.fetch(:enforcement), "payload_free_tombstone"
    assert_includes stream.fetch(:privacy_boundary), "separate encryption purposes"
    assert_includes stream.fetch(:excluded_pii), "provider_payload"
    assert_includes stream.fetch(:excluded_pii), "recipient_list"
  end

  def test_phone_auth_message_queue_contains_only_commit_aware_expiring_ciphertext
    stream = contract("phone_auth_message_queue")

    assert_equal ["encrypted_payload"], stream.fetch(:stored_fields)
    assert_includes stream.fetch(:enforcement), "ciphertext_only_job_arguments"
    assert_includes stream.fetch(:enforcement), "after_transaction_commit"
    assert_includes stream.fetch(:enforcement), "configured_job_scheduling"
    assert_includes stream.fetch(:enforcement), "serialize_defense"
    assert_includes stream.fetch(:enforcement), "auth_message_ttl_23_hours"
    assert_includes stream.fetch(:enforcement), "caller_earlier_deadline"
    assert_includes stream.fetch(:excluded_pii), "phone"
    assert_includes stream.fetch(:excluded_pii), "otp_code"
    assert_includes stream.fetch(:excluded_pii), "magic_link"
    assert_includes stream.fetch(:excluded_pii), "viber_template_parameters"
  end

  def test_viber_session_cache_is_hmac_keyed_short_lived_and_truthful_about_free_text
    stream = contract("viber_session_state_cache")

    assert_includes stream.fetch(:enforcement), "hmac_identity_key"
    assert_includes stream.fetch(:enforcement), "redis_ttl_10_minutes"
    assert_includes stream.fetch(:excluded_pii), "raw_sender"
    assert_includes stream.fetch(:excluded_pii), "viber_identifier"
    assert_includes stream.fetch(:stores), "citizen-supplied post text"
    assert_includes stream.fetch(:privacy_boundary), "10 minutes"
    assert_includes stream.fetch(:enforcement), "five_minute_effect_scrub"
    assert_includes stream.fetch(:enforcement), "payload_free_tombstone"
    refute_includes stream.fetch(:excluded_pii), "phone"
    refute_includes stream.fetch(:excluded_pii), "email"
    refute_includes stream.fetch(:excluded_pii), "address"
  end

  def test_komsiluk_naming_report_is_aggregate_and_excludes_membership_identity
    stream = contract("komsiluk_naming_campaign_report")

    assert_equal "host", stream.fetch(:owner)
    assert_includes stream.fetch(:stored_fields), "verified_active_participants"
    assert_includes stream.fetch(:stored_fields), "personal_prize_shortlist"
    assert_includes stream.fetch(:excluded_pii), "decidim_user_id"
    assert_includes stream.fetch(:excluded_pii), "phone_hash"
    assert_includes stream.fetch(:excluded_pii), "member_list"
    assert_includes stream.fetch(:enforcement), "assigned_profile_intersection"
    assert_includes stream.fetch(:enforcement), "sms_authorization_intersection"
    assert_includes stream.fetch(:tests), "test/services/decidim_app/bijeljina/komsiluk_naming_campaign_metrics_test.rb"
  end

  def test_public_impact_contract_expands_configured_public_mount_path
    stream = contract("public_impact_summary", mount_path: "/moja-platforma")

    assert_includes stream.fetch(:consumers), "/moja-platforma/uticaj"
    assert_nil stream.fetch(:consumers).index("/biceriseno/uticaj")
  end

  def test_full_host_contract_manifest_includes_privacy_event_contracts
    manifest = Decidim::Bih.host_contract_manifest(mount_path: "/moja-platforma")
    privacy_contract = manifest.fetch(:privacy_audit_contract)
    stream_ids = privacy_contract.fetch(:audit_event_streams).map { |stream| stream.fetch(:id) }
    bucket_ids = privacy_contract.fetch(:retention_buckets).map { |bucket| bucket.fetch(:id) }
    public_impact = privacy_contract.fetch(:audit_event_streams).find { |stream| stream.fetch(:id) == "public_impact_summary" }

    assert_equal 1, privacy_contract.fetch(:version)
    assert_equal EXPECTED_STREAM_IDS, stream_ids
    assert_equal EXPECTED_BUCKET_IDS, bucket_ids
    assert_includes privacy_contract.fetch(:required_exclusion_terms), "provider_payload"
    assert_includes public_impact.fetch(:consumers), "/moja-platforma/uticaj"
  end

  private

  def contract(id, mount_path: Decidim::Bih.public_mount_path)
    Decidim::Bih.required_audit_event_streams(mount_path:).find { |item| item.fetch(:id) == id }
  end

  def assert_non_empty_array(value)
    assert_instance_of Array, value
    assert value.any?
  end

  def assert_present_sentence(value)
    assert value.to_s.include?(" "), "#{value.inspect} should be descriptive"
  end
end
