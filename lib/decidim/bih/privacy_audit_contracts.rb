# frozen_string_literal: true

module Decidim
  module Bih
    module PrivacyAuditContracts
      RETENTION_BUCKETS = [
        {
          id: "channel_connections",
          service_cutoff_key: "channel_connection_before",
          env_cutoff_key: "CHANNEL_CONNECTION_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_channel_connections",
          removes: "Revoked scoped messaging connections after the approved retention period; recipient ciphertext is cleared on revocation.",
          excludes_from_run_history: %w(recipient_ciphertext recipient_digest decidim_user_id)
        },
        {
          id: "channel_connection_challenges",
          service_cutoff_key: "channel_connection_challenge_before",
          env_cutoff_key: "CHANNEL_CONNECTION_CHALLENGE_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_channel_connection_challenges",
          removes: "Expired messaging connection challenges; secret payloads expire independently after ten minutes.",
          excludes_from_run_history: %w(recipient_ciphertext token_digest confirmation_digest decidim_user_id)
        },
        {
          id: "citizen_phones",
          service_cutoff_key: "citizen_phone_before",
          env_cutoff_key: "CITIZEN_PHONE_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_citizen_phones",
          removes: "Sačuvani brojevi telefona verifikovanih građana poslije isteka operativne potrebe za SMS kanalom.",
          excludes_from_run_history: %w(phone decidim_user_id verified_at)
        },
        {
          id: "community_review_reasons",
          service_cutoff_key: "community_review_reason_before",
          env_cutoff_key: "COMMUNITY_REVIEW_REASON_BEFORE",
          action: "nullify_private_review_reasons",
          storage: "tables:decidim_bih_partner_project_submissions+decidim_bih_contribution_needs+decidim_bih_contribution_offers",
          removes: "Old private project, need and offer decision reasons while preserving workflow state and timestamps.",
          excludes_from_run_history: %w(rejection_reason decline_reason description address contact provider_payload)
        },
        {
          id: "chat_feedback",
          service_cutoff_key: "chat_feedback_before",
          env_cutoff_key: "CHAT_FEEDBACK_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_concierge_feedbacks",
          removes: "MI bot feedback rows, including consented review transcripts, after aggregate value has aged out.",
          excludes_from_run_history: %w(reply_id session_digest citizen_message bot_reply_text feedback_token)
        },
        {
          id: "komsiluk_delivery_data",
          service_cutoff_key: "komsiluk_delivery_before",
          env_cutoff_key: "KOMSILUK_DELIVERY_BEFORE",
          action: "delete_expired_terminal_data",
          storage: "tables:decidim_bih_platform_deliveries+decidim_bih_komsiluk_phone_deliveries+decidim_bih_komsiluk_send_intents",
          removes: "Expired terminal delivery audience rows and encrypted previews after an explicit cutoff at least 90 days old; " \
                   "unresolved provider handoffs remain for reconciliation.",
          excludes_from_run_history: %w(decidim_user_id identity destination_digest provider_message_ids payload_ciphertext member_list recipient_list)
        },
        {
          id: "komsiluk_post_bodies",
          service_cutoff_key: "komsiluk_post_body_before",
          env_cutoff_key: "KOMSILUK_POST_BODY_BEFORE",
          action: "nullify_body",
          storage: "table:decidim_bih_komsiluk_posts",
          removes: "Closed or expired Komšiluk free-text bodies, bounded revisions, private photos and help offers while preserving moderation status.",
          excludes_from_run_history: %w(body revision_content photo help_offer author_name phone email address recipient_list)
        },
        {
          id: "login_tokens",
          service_cutoff_key: "login_token_before",
          env_cutoff_key: "LOGIN_TOKEN_BEFORE",
          action: "destroy_terminal_rows",
          storage: "table:decidim_bih_login_tokens",
          removes: "Expired or consumed passwordless, verification and postal-link rows after the short operational window.",
          excludes_from_run_history: %w(token_digest phone decidim_user_id raw_token status_token)
        },
        {
          id: "operator_message_bodies",
          service_cutoff_key: "operator_message_body_before",
          env_cutoff_key: "OPERATOR_MESSAGE_BODY_BEFORE",
          action: "replace_body_with_retention_marker",
          storage: "table:decidim_bih_operator_messages",
          removes: "Old Decidim-only operator-to-user message bodies while preserving sender, recipient, subject and context metadata.",
          excludes_from_run_history: %w(body message raw_message recipient_email recipient_phone recipient_list)
        },
        {
          id: "partner_private_contacts",
          service_cutoff_key: "partner_private_contact_before",
          env_cutoff_key: "PARTNER_PRIVATE_CONTACT_BEFORE",
          action: "nullify_private_contact_fields",
          storage: "table:decidim_bih_partner_profiles",
          removes: "Private partner contact name, email and phone fields for old organization profiles.",
          excludes_from_run_history: %w(private_contact_name private_contact_email private_contact_phone email phone contact)
        },
        {
          id: "partner_verification_documents",
          service_cutoff_key: "partner_verification_document_before",
          env_cutoff_key: "PARTNER_VERIFICATION_DOCUMENT_BEFORE",
          action: "purge_active_storage_attachments",
          storage: "active_storage:decidim_bih_partner_profiles.verification_documents",
          removes: "Old partner verification document attachments and blobs after verification evidence has aged out.",
          excludes_from_run_history: %w(verification_documents blob_key filename document_url identity_document)
        },
        {
          id: "pending_registrations",
          lifecycle_service: "Decidim::Bih::Registration::PendingLifecycle",
          retention_days: 7,
          action: "destroy_stub_accounts",
          storage: "table:decidim_users",
          removes: "Unconfirmed one-step registrations (pending sms authorization, no sign-in, no points) seven days " \
                   "after creation, by the daily Registration::PendingLifecycle sweep — a hard delete, not anonymisation, " \
                   "on its own cron rather than the privacy sweep.",
          excludes_from_run_history: %w(email name phone token pending_token)
        },
        {
          id: "report_photo_drafts",
          lifecycle_service: "Decidim::Bih::ReportPhotoDraft",
          retention_hours: 2,
          action: "expire_session_owned_upload",
          storage: "table:decidim_bih_report_photo_drafts+active_storage",
          removes: "Normalized temporary upload and session-owner digest after two-hour access expiry. " \
                   "The expiry job removes the draft; the daily report reminder sweep recovers missed scheduling. " \
                   "Corroborating removes the owned unused draft early. Submitted report photos have their own lifecycle.",
          excludes_from_run_history: %w(owner_digest signed_token photo blob_key filename)
        },
        {
          id: "report_contacts",
          service_cutoff_key: "report_contact_before",
          env_cutoff_key: "REPORT_CONTACT_BEFORE",
          action: "nullify_contact_fields",
          storage: "table:decidim_bih_reports",
          removes: "Reporter email and phone fields for old reports.",
          excludes_from_run_history: %w(reporter_email reporter_phone reporter_name reporter_contact)
        },
        {
          id: "report_mail_linked",
          service_cutoff_key: "report_review_before",
          env_cutoff_key: "REPORT_REVIEW_BEFORE",
          action: "redact_mail_content",
          storage: "table:decidim_bih_inbound_emails+active_storage",
          removes: "Encrypted mail body, subject, raw MIME and attachments. Multi-linked mail survives while any report needs it; unlinked mail " \
                   "uses the explicit REPORT_REVIEW_BEFORE cutoff.",
          excludes_from_run_history: %w(raw subject body_text raw_ciphertext subject_ciphertext body_text_ciphertext token_ciphertext)
        },
        {
          id: "report_mail_unlinked",
          service_cutoff_key: "report_review_before",
          env_cutoff_key: "REPORT_REVIEW_BEFORE",
          action: "redact_mail_content",
          storage: "table:decidim_bih_inbound_emails+active_storage",
          removes: "Encrypted mail body, subject, raw MIME and attachments. Multi-linked mail survives while any report needs it; unlinked mail " \
                   "uses the explicit REPORT_REVIEW_BEFORE cutoff.",
          excludes_from_run_history: %w(raw subject body_text raw_ciphertext subject_ciphertext body_text_ciphertext token_ciphertext)
        },
        {
          id: "report_evidence_shares",
          service_cutoff_key: "report_review_before",
          env_cutoff_key: "REPORT_REVIEW_BEFORE",
          action: "purge_private_evidence_and_revoke_shares",
          storage: "table:decidim_bih_report_evidence_shares+decidim_bih_report_evidence_items+active_storage",
          removes: "Revoke service bearer access after reviewed cutoff only when all linked reports are terminal and inactive. Encrypted evidence " \
                   "copies are purged through their owned attachments; immutable checksum/source tombstones and dispatch joins remain. Shared " \
                   "source attachments retain bytes while needed by another owner; public report photos remain under their own policy. Vertex is " \
                   "processor for explicitly authorised attachment assessment; extracted PDF text is redacted. Sensitive flags block automatic " \
                   "handoff.",
          excludes_from_run_history: %w(token_ciphertext token_digest evidence_share_token blob_key filename assessment purge_descriptor_ciphertext)
        },
        {
          id: "report_dispatch_contents",
          service_cutoff_key: "report_review_before",
          env_cutoff_key: "REPORT_REVIEW_BEFORE",
          action: "redact_private_review_content",
          storage: "table:decidim_bih_report_dispatches",
          removes: "Approved mail content and reconciliation evidence after the approved cutoff, anchored to last update. " \
                   "Queued, sending and unknown outcomes are excluded; approval and transport outcome metadata remain.",
          excludes_from_run_history: %w(snapshot_ciphertext proposal_ciphertext reconciliation_evidence review_draft body contact)
        },
        {
          id: "report_review_proposals",
          service_cutoff_key: "report_review_before",
          env_cutoff_key: "REPORT_REVIEW_BEFORE",
          action: "redact_private_review_content",
          storage: "table:decidim_bih_report_review_proposals",
          removes: "Private AI proposal content after the approved cutoff, anchored to last update. Human decision and correction metadata remain.",
          excludes_from_run_history: %w(snapshot_ciphertext proposal_ciphertext reconciliation_evidence review_draft body contact)
        },
        {
          id: "report_review_drafts",
          service_cutoff_key: "report_review_before",
          env_cutoff_key: "REPORT_REVIEW_BEFORE",
          action: "redact_private_review_content",
          storage: "table:decidim_bih_reports",
          removes: "Unsaved decision content once the report has no updates since the approved cutoff. Recent case work preserves its draft.",
          excludes_from_run_history: %w(snapshot_ciphertext proposal_ciphertext reconciliation_evidence review_draft body contact)
        },
        {
          id: "report_coordinates",
          service_cutoff_key: "report_coordinates_before",
          env_cutoff_key: "REPORT_COORDINATES_BEFORE",
          precision_key: "report_coordinate_precision",
          precision_env_key: "REPORT_COORDINATE_PRECISION",
          action: "nullify_or_round_coordinates",
          storage: "table:decidim_bih_reports",
          removes: "Exact report latitude and longitude, or rounds them to the approved precision.",
          excludes_from_run_history: %w(latitude longitude address exact_location)
        },
        {
          id: "report_photos",
          service_cutoff_key: "report_photo_before",
          env_cutoff_key: "REPORT_PHOTO_BEFORE",
          action: "purge_active_storage_attachment",
          storage: "active_storage:decidim_bih_reports.photo",
          removes: "Old report photo attachments and blobs.",
          excludes_from_run_history: %w(photo_url blob_key filename exif gps_metadata)
        },
        {
          id: "viber_linkages",
          service_cutoff_key: "viber_linkage_before",
          env_cutoff_key: "VIBER_LINKAGE_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_viber_linkages",
          removes: "Old Viber sender/user linkage rows.",
          excludes_from_run_history: %w(viber_sender phone sender_profile provider_payload)
        },
        {
          id: "messaging_attempts",
          service_cutoff_key: "messaging_attempt_before",
          env_cutoff_key: "MESSAGING_ATTEMPT_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_messaging_attempts",
          removes: "Operativni zapisi o pokušajima isporuke poruka nakon isteka roka čuvanja; sadržaj poruke se ovdje nikada ne čuva.",
          excludes_from_run_history: %w(destination_digest destination_version provider_message_id provider_message_ids intent_id)
        },
        {
          id: "messaging_suppressions",
          service_cutoff_key: "messaging_suppression_before",
          env_cutoff_key: "MESSAGING_SUPPRESSION_BEFORE",
          action: "destroy_reactivated_rows",
          storage: "table:decidim_bih_messaging_suppressions",
          removes: "Zapisi o zabrani slanja koji su već razriješeni (reaktivirani) i stariji su od roka; aktivna zabrana se nikada ne briše.",
          excludes_from_run_history: %w(destination_digest reactivation_evidence event_ref decidim_user_id)
        },
        {
          id: "account_notifications",
          service_cutoff_key: "account_notification_before",
          env_cutoff_key: "ACCOUNT_NOTIFICATION_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_account_notifications",
          removes: "Encrypted notification content and delivery metadata.",
          excludes_from_run_history: %w(payload_ciphertext provider_message_ids)
        },
        {
          id: "viber_business_contacts",
          service_cutoff_key: "viber_business_contact_before",
          env_cutoff_key: "VIBER_BUSINESS_CONTACT_BEFORE",
          action: "destroy_rows",
          storage: "table:decidim_bih_viber_business_contacts",
          removes: "Old Viber Business Messages delivery addresses.",
          excludes_from_run_history: %w(phone sender_profile provider_payload)
        },
        {
          id: "volunteer_availabilities",
          service_cutoff_key: "volunteer_availability_before",
          env_cutoff_key: "VOLUNTEER_AVAILABILITY_BEFORE",
          action: "nullify_sensitive_profile",
          storage: "table:decidim_bih_volunteer_availabilities",
          removes: "Volunteer availability free-text, area preference, broad schedule, interests, skills and capabilities.",
          excludes_from_run_history: %w(
            availability interests area_scope local_area_id availability_windows interest_keys
            day_keys month_keys time_slot_keys skill_keys capability_keys phone email schedule_note
          )
        }
      ].sort_by { |bucket| bucket.fetch(:id) }.freeze

      AUDIT_EVENT_STREAMS = [
        {
          id: "platform_delivery_receipts",
          owner: "engine",
          storage: "table:decidim_bih_platform_deliveries",
          producer: "Decidim::Bih::PlatformDelivery",
          consumers: %w(platform_receipts inbox_mark_read city_service_fallback delivery_review),
          stores: "Private per-recipient delivery evidence and optional fallback authorization, separate from provider acceptance and message content.",
          stored_fields: %w(id decidim_organization_id decidim_user_id identity expires_at deadline_at
                            inbox_created_at acknowledged_at acknowledgment_kind push_queued_at push_intent_id
                            fallback_requested_at fallback_context account_notification_id komsiluk_post_id publication_revision
                            cancelled_at cancellation_reason browser_displayed_at inbox_read_at created_at updated_at),
          allowed_metadata: %w(event_id event_revision dedupe_key browser_display inbox_read),
          excluded_pii: %w(phone email address recipient_list member_list notification_body raw_citizen_message
                           push_endpoint push_auth push_p256dh receipt_token provider_payload credentials),
          privacy_boundary: "Account references and receipt timing remain private operational evidence. Browser display is not human reading. " \
                            "expires_at ends dispatch and signed-token validity; captured board receipts use the explicit KOMSILUK_DELIVERY_BEFORE retention cutoff. " \
                            "Soft account deletion preserves evidence and disables dispatch; hard account or organization deletion cascades receipt removal.",
          enforcement: %w(unique_organization_user_identity tenant_scoped_signed_receipt expiring_capability
                          explicit_read_lock final_dispatch_receipt_lock cascade_hard_account_deletion no_message_payload),
          tests: %w(test/integration/decidim/bih/platform_receipts_test.rb
                    test/jobs/decidim_app/bijeljina/city_service_alert_notification_job_test.rb
                    test/javascript/service_worker_delivery_receipt_test.js)
        },
        {
          id: "city_service_incident_workflow",
          owner: "host",
          storage: "tables:decidim_app_city_service_incidents+decidim_app_city_service_projections+" \
                   "decidim_app_city_service_duplicate_decisions+decidim_app_city_service_effects+" \
                   "decidim_app_city_service_coverages+decidim_app_city_service_automation_decisions",
          producer: "DecidimApp::Bijeljina::CityServiceIncident",
          consumers: %w(city_alerts_review komsiluk_system_posts source_automation durable_effect_recovery),
          stores: "Canonical public-source incident links, board projections, reviewer-attributed duplicate and geographic decisions, " \
                  "automation outcomes and metadata-only delivery outbox.",
          stored_fields: %w(id decidim_organization_id identity_key service incident_id komsiluk_id post_id revision
                            event_id other_event_id decision reviewer_id previous_memberships identity kind payload
                            completed_at last_attempt_at attempts error_code source_key targeting_level area_slugs evidence
                            valid_until revoked_at policy_version content_version mode outcome blockers target_slugs created_at updated_at),
          allowed_metadata: %w(event_id event_revision delivery_identity post_id board_url delivery_expires_at
                               source_key identity_key incident_id policy_version content_version target_slugs
                               previous_memberships quoted_affected_phrase geometry_version geometry_provenance),
          excluded_pii: %w(recipient_list user_ids member_list phone email address citizen_name raw_citizen_message
                           notification_body raw_provider_dump raw_html provider_payload push_endpoint credentials),
          privacy_boundary: "Reviewer references identify accountable operators; geographic evidence describes public service areas, never citizen locations. " \
                            "Outbox rows contain event/revision identifiers and bounded control metadata, never recipient snapshots or contact payloads. " \
                            "Operational expiry is not deletion; no additional timed purge is declared for these records.",
          enforcement: %w(organization_scoped_incident_identity unique_incident_board unique_effect_identity
                          metadata_only_outbox reversible_duplicate_audit reviewed_coverage_validity source_policy_version),
          tests: %w(test/services/decidim_app/bijeljina/city_service_incident_safety_test.rb
                    test/services/decidim_app/bijeljina/city_service_automation_safety_test.rb
                    test/integration/decidim_app/admin/city_service_events_controller_test.rb)
        },
        {
          id: "notification_topic_preferences",
          owner: "engine",
          storage: "tables:decidim_bih_messaging_preferences+decidim_bih_messaging_preference_changes",
          producer: "Decidim::Bih::TopicPreferences",
          consumers: %w(notification_settings proactive_delivery_policy preference_history_review),
          stores: "Four topic states per citizen with origin and revision; append-only history retains original legacy topic/channel choices.",
          stored_fields: %w(decidim_organization_id decidim_user_id topic state source policy_version change_id changed_at imported_from
                            previous_state new_state previous_source actor_type actor_id operation ui_revision recorded_at historical_channel),
          allowed_metadata: %w(topic state source policy_version change_id operation),
          excluded_pii: %w(phone email address description raw_citizen_message bot_reply_text provider_payload recipient_list member_list
                           push_endpoint push_auth push_p256dh credentials),
          privacy_boundary: "Account and actor references are private operational evidence, never public analytics. Current choices have no channel dimension; " \
                            "device secrets, channel identity, transport suppression and delivery content stay outside this store.",
          enforcement: %w(tenant_scoped_user_lock unique_user_topic current_topic_constraint append_only_history no_matrix_json),
          tests: %w(test/services/decidim/bih/topic_preference_migration_test.rb)
        },
        {
          id: "milica_prepared_public_sources",
          owner: "host",
          storage: "table:city_service_source_snapshots",
          producer: "DecidimApp::Bijeljina::CityServiceSourceCheckStore",
          consumers: %w(Milica_ReadPort LiveServiceAnswers city_alerts_review),
          stores: "Bounded public source observations, parsed timetables, reviewed reference metadata, last-good versions and twelve health-history entries.",
          stored_fields: %w(source_key source_version check_payload last_good_payload attempted_at last_success_at content_hash lock_version),
          allowed_metadata: %w(status checked_at error_code source_url content_hash source_version coverage public_measurement),
          excluded_pii: %w(raw_citizen_message bot_reply_text phone email donor_identity member_list recipient_list session_digest user_name provider_payload credentials
                           private_report),
          privacy_boundary: "Public allowlisted sources only; no citizen conversation or authentication context. " \
                            "Latest and last-good payloads are bounded; history stores health scalars only.",
          enforcement: %w(source_registry bounded_collectors MAX_ITEMS_30 HISTORY_LIMIT_12 last_good_versions),
          tests: %w(test/services/decidim_app/bijeljina/city_service_source_check_store_test.rb test/services/decidim_app/bijeljina/public_transport_preparation_test.rb)
        },
        {
          id: "milica_public_place_suggestions",
          owner: "host",
          storage: "cache:milica/public-place",
          producer: "DecidimApp::Bijeljina::CityServiceAreaPreparation",
          consumers: %w(city_alerts_review),
          stores: "Coordinates for public provider street/settlement descriptions; seven-day success TTL, one-hour negative TTL and six-second shared geocoder lease.",
          stored_fields: %w(organization_id query_digest lat lon),
          allowed_metadata: %w(public_source_location source_content_version candidate_slug),
          excluded_pii: %w(citizen_address citizen_message user_id recipient_list credentials),
          privacy_boundary: "Only official public notice locations enter this background cache. Citizen registration geocoding remains transient. " \
                            "Event suggestions retain candidate slugs and public evidence, not coordinates; suggestions do not approve coverage.",
          enforcement: %w(tenant_scoped_digest_keys bounded_ttl background_only shared_request_lease source_version_binding no_auto_approval),
          tests: %w(test/services/decidim_app/bijeljina/city_service_area_preparation_test.rb)
        },
        {
          id: "milica_read_timing_aggregates",
          owner: "host",
          storage: "redis:milica/read-metrics/v1",
          producer: "DecidimApp::Bijeljina::Milica::ReadMetrics",
          consumers: %w(milica_data_status operator_performance_review),
          stores: "Hourly counts by allowlisted topic, result status and fixed latency bucket, expiring after 48 hours.",
          stored_fields: %w(hour topic stage status latency_bucket count),
          allowed_metadata: %w(topic action stage status duration_ms),
          excluded_pii: %w(raw_citizen_message bot_reply_text phone email donor_identity member_list recipient_list session_digest user_name provider_payload address location
                           conversation_key actor_id),
          privacy_boundary: "No identities, queries or location dimensions. Failure to record a counter never changes a citizen answer.",
          enforcement: %w(Contracts_TOPICS Contracts_ACTIONS Contracts_READ_STATUSES fixed_latency_buckets redis_ttl_48_hours),
          tests: %w(test/services/decidim_app/bijeljina/milica/read_metrics_test.rb)
        },
        {
          id: "milica_model_usage_reservations",
          owner: "host",
          storage: "redis:decidim-bih:milica:model-led:usage:v1",
          producer: "DecidimApp::Bijeljina::Milica::ConversationUsage",
          consumers: %w(model_spend_admission operator_cost_review),
          stores: "Organization/day provider spend reservations, settled token counts and costs; expires after 48 hours.",
          stored_fields: %w(committed_micro_usd reserved_calls settled_micro_usd settled_calls input_tokens output_tokens),
          allowed_metadata: %w(organization_id day phase input_tokens output_tokens cost_micro_usd),
          excluded_pii: %w(raw_citizen_message bot_reply_text actor_id conversation_key session_digest address location provider_payload phone email),
          privacy_boundary: "Aggregate spend only. Unknown usage keeps its reservation; provider failure cannot grant a retry.",
          enforcement: %w(organization_day_key redis_ttl_48_hours atomic_reserve_before_dispatch two_call_limit),
          tests: %w(test/contracts/milica_conversation_usage_test.rb)
        },
        {
          id: "milica_answer_outcome_aggregates",
          owner: "host",
          storage: "redis:milica/answer-metrics/v1",
          producer: "DecidimApp::Bijeljina::Milica::AnswerMetrics",
          consumers: %w(milica_data_status unmet_demand_review),
          stores: "Hourly allowlisted topic/outcome counts from instrumented answer boundaries; expiry after 48 hours.",
          stored_fields: %w(hour topic outcome count),
          allowed_metadata: %w(topic outcome),
          excluded_pii: %w(raw_citizen_message bot_reply_text actor_id organization_id conversation_key session_digest address location provider_payload),
          privacy_boundary: "No identity, transcript, channel or location dimensions. Technical outcomes are not factual accuracy or citizen satisfaction.",
          enforcement: %w(Contracts_TOPICS AnswerOutcome_OUTCOMES redis_ttl_48_hours fail_open_metrics),
          tests: %w(test/services/decidim_app/bijeljina/milica/answer_metrics_test.rb)
        },
        {
          id: "admin_analytics_exports",
          owner: "engine",
          storage: "derived_csv:Decidim::Bih::Admin::AnalyticsSummary",
          producer: "Decidim::Bih::Admin::AnalyticsSummary",
          consumers: %w(/admin/bih/analytics /admin/bih/analytics/export/:dataset decidim_bih:analytics:digest),
          stores: "Aggregate counts, totals, dates, status buckets, review priorities and bounded answer-intent labels.",
          stored_fields: %w(dataset headers rows aggregate_counts aggregate_totals dates review_priority review_action),
          allowed_metadata: %w(outcome answer_intent reply_length quick_replies_count),
          excluded_pii: %w(
            donor_identity payment_reference report_reference status_token report_contact report_description report_address
            report_coordinates user_name nickname email phone member_list recipient_list
            viber_identifier whatsapp_identifier messenger_identifier instagram_identifier
            raw_bot_prompt bot_reply_text feedback_reply_id reply_id session_digest
            komsiluk_post_body provider_payload payout_reference csv_attachment raw_export_attachment
          ),
          privacy_boundary: "Admin analytics exports are aggregate operational reports, not row-level evidence exports.",
          enforcement: %w(aggregate_grouping safe_csv_value dataset_headers digest_sections no_digest_attachments),
          tests: %w(
            test/services/decidim/bih/admin/analytics_summary_test.rb
            test/tasks/analytics_digest_test.rb
            test/system/admin_analytics_test.rb
          )
        },
        {
          id: "city_content_overrides",
          owner: "host",
          storage: "table:decidim_app_city_service_entries+decidim_app_foundation_status_overrides",
          producer: "DecidimApp::Admin::CityServiceEntriesController and FoundationStatusController (operator drafts, approvals, rollbacks)",
          consumers: %w(DecidimApp::Bijeljina::CityDirectory DecidimApp::Bijeljina::Milica::FoundationRead DecidimApp::Bijeljina::ContentReviewReminders),
          stores: "One reviewed override per organization and FAQ key (title, body, source URL, source check date, content hash, " \
                  "review state, approval time and approving operator id) and one foundation call-status override per organization.",
          stored_fields: %w(
            decidim_organization_id key title body source_url source_checked_on reviewed_content_hash state approved_at approved_by_id
            current_open_status reviewed_on review_expires_on created_at updated_at
          ),
          allowed_metadata: %w(key state source_checked_on reviewed_on review_expires_on approved_at),
          excluded_pii: %w(
            raw_citizen_message bot_reply_text session_digest conversation_key actor_id channel_sender viber_sender
            whatsapp_identifier messenger_identifier instagram_identifier phone email address location coordinates
            ip_address user_agent provider_payload free_text
          ),
          privacy_boundary: "Operator-authored public content only: no citizen data is ever written, approved_by_id is an operator audit " \
                            "field, and only rows whose content hash matches their approved body reach the chat.",
          enforcement: %w(
            CityServiceEntry_STATES reviewed_content_hash_match OperatorAuthorization_city_alerts_manage unique_org_key_index
          ),
          tests: %w(
            test/models/decidim_app/city_service_entry_test.rb
            test/integration/decidim_app/admin/city_service_entries_controller_test.rb
            test/services/decidim_app/bijeljina/city_directory_test.rb
            test/services/decidim_app/bijeljina/milica/foundation_read_override_test.rb
          )
        },
        {
          id: "city_service_events",
          owner: "host",
          storage: "table:decidim_app_city_service_events",
          producer: "DecidimApp::Bijeljina::CityServiceEventIngestor",
          consumers: %w(/admin/bih/city-alerts mi_bot_city_event_answers komsiluk_system_posts city_service_alerts),
          stores: "Sanitized official city-service event candidates, operator review state, Komšiluk post ids and aggregate Viber delivery counts.",
          stored_fields: %w(
            decidim_organization_id reviewed_by_id source_key source_label provider source_url
            source_fingerprint fetched_at parser_version event_type severity targeting_level
            affected_area_slugs target_komsiluk_slugs title summary affected_text recommended_action
            viber_text starts_at ends_at confidence state reviewed_at published_at dismissed_at
            review_note classifier_reasons komsiluk_post_ids viber_dedupe_key viber_delivery
            viber_jobs_count viber_recipients_count policy_snapshot created_at updated_at
            source_occurrence_id content_version source_published_at source_updated_at extraction_metadata lifecycle reviewed_content_version superseded_by_id
          ),
          allowed_metadata: %w(
            source_key source_fingerprint parser_version event_type severity targeting_level
            affected_area_slugs target_komsiluk_slugs confidence classifier_reasons policy_snapshot
            source_occurrence_id content_version source_published_at source_updated_at lifecycle reviewed_content_version
            superseded_by_id confidence_by_field coverage source_withdrawal area_review_suggestions place_context
            viber_dedupe_key viber_delivery viber_jobs_count viber_recipients_count komsiluk_post_ids
          ),
          excluded_pii: %w(
            raw_provider_dump provider_payload raw_gemini_prompt raw_model_response raw_html
            recipient_list member_list viber_sender phone email address citizen_name report_content
            citizen_report_body ip_address user_agent webhook_payload delivery_payload
          ),
          privacy_boundary: "City-service events are operator-reviewed official-source notices; they may store sanitized " \
                            "public notice text and aggregate delivery counts, never raw source dumps or recipient identities.",
          enforcement: %w(source_specific_parser sanitized_fields admin_only aggregate_recipient_counts opt_out_aware_viber locked_review_version complete_source_reconciliation
                          factual_areas_separate_from_notification_candidates),
          tests: %w(
            test/services/decidim_app/bijeljina/city_service_event_workflow_test.rb
            test/services/decidim_app/bijeljina/city_service_source_reconciler_test.rb
            test/integration/decidim_app/admin/city_service_events_controller_test.rb
            test/services/decidim/bih/concierge/responder_test.rb
          )
        },
        {
          id: "concierge_feedback",
          owner: "engine",
          storage: "table:decidim_bih_concierge_feedbacks",
          producer: "Decidim::Bih::Concierge::WebChatController#feedback",
          consumers: %w(mi_bot_feedback mi_bot_review mi_bot_answer_review_queue mi_bot_answer_review_examples trends privacy_retention_sweep milica_data_status_grouped_topics),
          stores: "One rating per signed answer/session digest plus locale, bounded answer metadata and the exact prompt/reply only after a feedback click.",
          stored_fields: %w(
            decidim_organization_id decidim_user_id reply_id session_digest value locale metadata
            citizen_message bot_reply_text created_at updated_at
          ),
          allowed_metadata: %w(source outcome answer_intent topic reply_length quick_replies_count sticker issued_at),
          excluded_pii: %w(
            phone email address ip_address user_agent account_identity user_name
            viber_sender whatsapp_identifier messenger_identifier instagram_identifier
            request_params free_text session_id feedback_token provider_payload
          ),
          privacy_boundary: "Feedback rows store the rated prompt/reply only after explicit helpful/not-helpful feedback and must remain anonymous.",
          enforcement: %w(
            message_verifier REPLY_ID_FORMAT feedback_session_digest VALID_ANSWER_INTENTS Contracts_TOPICS
            anonymous_feedback_user mi_bot_examples_read
          ),
          tests: %w(
            test/integration/decidim/bih/web_chat_test.rb
            test/services/decidim/bih/admin/analytics_summary_test.rb
            test/system/admin_analytics_test.rb
          )
        },
        {
          id: "milica_dimensioned_answer_counters",
          owner: "host",
          storage: "redis:milica/answer-dimensions/v1",
          producer: "milica.answer_dimensions via DimensionedAnswerMetrics",
          consumers: %w(DecidimApp::Bijeljina::Milica::MetricRollup),
          stores: "48-hour Redis hashes of tenant/hour partitioned topic, facet, typed outcome, trusted traffic class, process release and prompt version counts.",
          stored_fields: %w(organization_partition utc_hour topic facet label traffic_kind release_sha prompt_version count),
          allowed_metadata: %w(topic facet label traffic_kind release_sha prompt_version count),
          excluded_pii: %w(citizen_message bot_reply_text user_id session_digest sender phone email address coordinates provider_payload),
          privacy_boundary: "Closed labels only; tenant partition stays internal. Synthetic is trusted process configuration, not a request parameter. No unique-person counts.",
          enforcement: %w(fixed_vocabularies tenant_partition max_hash_fields redis_expiry_48_hours sparse_export_suppression),
          tests: %w(test/services/decidim_app/bijeljina/milica/dimensioned_answer_metrics_test.rb)
        },
        {
          id: "concierge_metric_rollups",
          owner: "engine",
          storage: "table:decidim_bih_concierge_metric_rollups",
          producer: "rake decidim_bih:concierge:rollup_metrics (host, nightly) via Decidim::Bih::ConciergeMetricRollup",
          consumers: %w(Decidim::Bih::Admin::ChatHealthSummary Decidim::Bih::Admin::ConciergeMetricsSummary admin_analytics_chat_health admin_analytics_metrics),
          stores: "One row per organization, Europe/Sarajevo day, metric kind (answer, answer_detail, read, stage), bounded topic, bounded label " \
                  "and fixed latency bucket. Answer detail adds facet and trusted traffic provenance; legacy release stamps describe " \
                  "the rollup checkout, new stamps the process boot checkout.",
          stored_fields: %w(
            decidim_organization_id day kind topic label count latency_bucket release_sha prompt_version facet traffic_kind created_at updated_at
          ),
          allowed_metadata: %w(day kind topic label latency_bucket count release_sha prompt_version facet traffic_kind),
          excluded_pii: %w(
            raw_citizen_message bot_reply_text session_digest conversation_key actor_id decidim_user_id channel_sender
            viber_sender whatsapp_identifier messenger_identifier instagram_identifier phone email address location
            coordinates ip_address user_agent provider_payload free_text
          ),
          privacy_boundary: "Rollups keep the 48-hour Redis histograms as day-level counts only; every dimension is a fixed " \
                            "vocabulary enforced by the model, a missing row means not rolled up rather than zero, and no channel, " \
                            "citizen identity, text or location dimension exists. Detail counters are tenant-partitioned; exports suppress sparse cells and complementary totals.",
          enforcement: %w(
            ConciergeMetricRollup_KINDS Contracts_TOPICS AnswerOutcome_OUTCOMES Contracts_READ_STATUSES
            fixed_latency_buckets rollup_unique_index positive_counts_only
          ),
          tests: %w(
            test/models/decidim/bih/concierge_metric_rollup_test.rb
            test/tasks/milica_metrics_rollup_test.rb
            test/services/decidim/bih/admin/chat_health_summary_test.rb
          )
        },
        {
          id: "concierge_usage_aggregates",
          owner: "engine",
          storage: "table:decidim_bih_concierge_usage_aggregates",
          producer: "Decidim::Bih::Concierge::UsageAggregateRecorder",
          consumers: %w(mi_bot_usage trends admin_analytics_exports Decidim::Bih::Admin::ChatHealthSummary),
          stores: "Daily aggregate MI bot usage counters by organization, channel, outcome, bounded answer intent and locale.",
          stored_fields: %w(
            decidim_organization_id bucket_on channel outcome answer_intent locale requests_count
            message_length_total reply_length_total quick_replies_total sticker_count created_at updated_at
          ),
          allowed_metadata: %w(channel outcome answer_intent locale counts totals averages bucket_on),
          excluded_pii: %w(
            raw_citizen_message bot_reply_text reply_id session_digest feedback_token viber_sender
            whatsapp_identifier messenger_identifier instagram_identifier
            phone email address ip_address user_agent provider_payload request_params free_text session_id
          ),
          privacy_boundary: "Usage aggregates support coverage review without storing conversations, senders, sessions or reply tokens.",
          enforcement: %w(UsageAggregateRecorder AnswerIntents aggregate_unique_index admin_analytics_grouping),
          tests: %w(
            test/services/decidim/bih/concierge/usage_aggregate_recorder_test.rb
            test/integration/decidim/bih/web_chat_test.rb
            test/services/decidim/bih/admin/analytics_summary_test.rb
          )
        },
        {
          id: "milica_conversation_location",
          owner: "engine+host",
          storage: "redis:decidim-bih:milica:dialogue:v1/<organization>/<actor>/<conversation>",
          producer: "DecidimApp::Bijeljina::Milica::ConversationMemory",
          consumers: %w(DecidimApp::Bijeljina::Milica::ModelLedCoordinator public_read_tools),
          stores: "One bounded active place, encrypted exact point or typed address, journey constraints, three public subject identifiers and " \
                  "script preference. The Redis value expires after 30 minutes of inactivity.",
          stored_fields: %w(conversation_slots_v1 location_kind location_label place_id ciphertext acquired_at expires_at journey subject_ids script),
          allowed_metadata: %w(slot_present location_kind byte_size expiry_seconds),
          excluded_pii: %w(raw_coordinates plaintext_address citizen_message raw_provider_payload exact_point_in_prompt report_prefill feedback_projection),
          privacy_boundary: "Exact coordinates and typed addresses use distinct MessageEncryptor keys and tenant/actor/conversation purposes. " \
                            "The optional location is never an implicit public report position. Forget/reset clears the live slot; backup retention is separately governed.",
          enforcement: %w(strict_slot_schema maximum_2000_bytes maximum_state_12000_bytes isolated_key_and_purpose
                          encrypted_exact_point encrypted_typed_address inactivity_ttl_30_minutes no_implicit_report_location),
          tests: %w(test/services/decidim/bih/concierge/dialogue/state_store_test.rb
                    test/services/decidim_app/bijeljina/milica/model_led_coordinator_test.rb)
        },
        {
          id: "external_chat_conversation_cache",
          owner: "host",
          storage: "redis:decidim-bih/external-chat/conversation/<organization>/<channel>/<hmac>",
          producer: "DecidimApp::Bijeljina::ExternalChatSessionStore",
          consumers: %w(DecidimApp::Bijeljina::ExternalChatConcierge DecidimApp::Bijeljina::Concierge),
          stores: "At most six bounded citizen/assistant text turns, which may contain voluntarily supplied personal data, plus " \
                  "answer-intent/tone/phrase labels, a compact ten-item non-PII tone history, location-presence booleans and " \
                  "timestamps for 30 minutes plus at most one five-minute scrub interval.",
          stored_fields: %w(
            organization_id channel hmac_sender_digest turns user bot answer_intent tone phrase_id tone_history location_present at
          ),
          allowed_metadata: %w(channel answer_intent tone phrase_id tone_history location_present at turn_count),
          excluded_pii: %w(
            raw_sender sender_in_cache_key viber_identifier whatsapp_identifier messenger_identifier instagram_identifier
            provider_contact_name provider_username provider_contact_phone provider_contact_email
            provider_contact_address raw_coordinates media_url provider_payload webhook_payload
            referral_metadata api_key token
          ),
          privacy_boundary: "Short-lived conversational text can include personal data a citizen voluntarily types; cache expiry is " \
                            "30 minutes and a captured undelivered slot is scrubbed within the five-minute recovery cadence. " \
                            "Structured provider/contact fields and raw coordinates are excluded, " \
                            "the cache key uses an HMAC instead of a raw identity, and no durable identity/transcript row is persisted. " \
                            "The same boundary covers Viber Bot and external Meta follow-up context.",
          enforcement: %w(
            hmac_identity_key no_raw_sender_in_key MAX_TURNS_6 MAX_TONE_HISTORY_10 bounded_turn_text redis_ttl_30_minutes
            effect_deadline five_minute_effect_scrub payload_free_tombstone no_database_transcript
          ),
          tests: %w(
            test/services/decidim_app/bijeljina/external_chat_concierge_test.rb
          )
        },
        {
          id: "external_chat_reply_queue",
          owner: "engine",
          storage: "active_job:integrations:encrypted_payload",
          producer: "Decidim::Bih::Infobip::SendChatTextJob",
          consumers: %w(ActiveJob Sidekiq Decidim::Bih::Infobip::Client),
          stores: "One authenticated ciphertext whose plaintext is a bounded channel reply envelope with a deadline no later than 23 hours after enqueue.",
          stored_fields: %w(encrypted_payload),
          allowed_metadata: %w(job_class queue_name attempts error_class http_status error_code error_group),
          excluded_pii: %w(
            plaintext_job_arguments raw_sender raw_recipient raw_reply_text whatsapp_identifier
            messenger_identifier instagram_identifier provider_payload provider_response error_message
          ),
          privacy_boundary: "ActiveJob and failed-job metadata receive ciphertext only; recipient, reply text, sender and expiry " \
                            "are decrypted inside the worker; the delivery error retains only numeric HTTP status and allowlisted " \
                            "provider code/group, while exhaustion logs contain only bounded channel, status, code and group.",
          enforcement: %w(
            MessageEncryptor isolated_key_and_purpose ciphertext_only_job_arguments log_arguments_false
            after_transaction_commit before_enqueue serialize_defense configured_job_scheduling expiry_inside_envelope
            session_reply_ttl_23_hours channel_only_exhaustion_log safe_delivery_error
            allowlisted_provider_error_metadata
          ),
          tests: %w(
            test/jobs/decidim/bih/infobip/send_chat_text_job_test.rb
            test/services/decidim/bih/infobip/client_test.rb
            test/services/decidim/bih/infobip/error_test.rb
          )
        },
        {
          id: "community_contribution_workflows",
          owner: "engine",
          storage: "tables:decidim_bih_partner_project_submissions+decidim_bih_project_donation_links+" \
                   "decidim_bih_contribution_needs+decidim_bih_contribution_offers",
          producer: "Decidim::Bih project, need and offer lifecycle services",
          consumers: %w(community_projects volunteering /admin/bih/community-contributions),
          stores: "Tenant-scoped moderated project drafts, canonical project campaign links, non-cash needs, offer state and bounded private review reasons.",
          stored_fields: %w(
            decidim_organization_id partner_profile_id decidim_user_id decidim_author_id reviewed_by_id
            accepted_by_id declined_by_id confirmed_by_id recognized_by_id
            decidim_budgets_project_id contribution_need_id need_type title description budget_amount
            quantity unit address location starts_on ends_on needed_by review_status fulfillment_status
            status campaign_key active submitted_at reviewed_at published_at accepted_at declined_at
            withdrawn_at delivered_at confirmed_at recognized_at closed_at rejection_reason decline_reason
            lock_version created_at updated_at
          ),
          allowed_metadata: %w(resource_id partner_profile_id project_id need_id offer_id status campaign_key),
          excluded_pii: %w(
            phone email private_contact employee_name employee_list member_list donor_identity
            payment_reference bank_account provider_payload delivery_evidence recipient_list ip_address user_agent
          ),
          privacy_boundary: "Drafts and review reasons stay limited to the submitting partner and LFBN reviewers; " \
                            "approved native projects remain durable public transparency records, while active catalog, " \
                            "fundraising and help use their own current eligibility gates; public impact exposes only LFBN-recognized aggregates.",
          enforcement: %w(organization_scoping verified_partner_gate review_state_machine csrf_post bounded_text no_cash_need),
          tests: %w(
            test/models/decidim/bih/community_contribution_policy_test.rb
            test/services/decidim/bih/community_contribution_services_test.rb
          )
        },
        {
          id: "phone_auth_message_queue",
          owner: "engine",
          storage: "active_job:integrations:phone_auth_encrypted_payload",
          producer: "Decidim::Bih::Infobip::SendPhoneMessageJob",
          consumers: %w(ActiveJob Sidekiq Decidim::Bih::Infobip::Client),
          stores: "One authenticated ciphertext whose plaintext is a bounded phone-authentication envelope with a deadline " \
                  "no later than 23 hours after enqueue or the caller's earlier deadline.",
          stored_fields: %w(encrypted_payload),
          allowed_metadata: %w(job_class queue_name attempts error_class http_status error_code error_group),
          excluded_pii: %w(
            plaintext_job_arguments phone raw_recipient raw_message_text otp_code magic_link raw_token
            viber_template_parameters messenger_identifier provider_payload provider_response error_message
          ),
          privacy_boundary: "ActiveJob and failed-job metadata receive ciphertext only; the phone, OTP or magic-link text, " \
                            "optional Viber text/template, Messenger session and expiry are decrypted inside the worker. " \
                            "Rollback publishes no job, and exhaustion diagnostics contain only channel and allowlisted provider metadata.",
          enforcement: %w(
            MessageEncryptor isolated_key_and_purpose ciphertext_only_job_arguments log_arguments_false
            after_transaction_commit before_enqueue serialize_defense configured_job_scheduling expiry_inside_envelope
            auth_message_ttl_23_hours caller_earlier_deadline safe_delivery_error channel_only_exhaustion_log
            allowlisted_provider_error_metadata
          ),
          tests: %w(
            test/jobs/decidim/bih/infobip/send_phone_message_job_test.rb
            test/services/decidim/bih/infobip/client_test.rb
            test/services/decidim/bih/infobip/error_test.rb
          )
        },
        {
          id: "goodwill_match_requests",
          owner: "engine",
          storage: "table:decidim_bih_goodwill_match_requests",
          producer: "Decidim::Bih::Goodwill::MatchRequest",
          consumers: %w(admin_goodwill finance_sop),
          stores: "Mutable matched-giving decision and manual payout bookkeeping state with payout event metadata.",
          stored_fields: %w(
            decidim_organization_id owner_type owner_id status points created_by_id decided_by_id decided_at
            payout_status payout_amount_minor_units payout_currency payout_reference payout_note payout_paid_on
            payout_recorded_by_id payout_recorded_at metadata created_at updated_at
          ),
          allowed_metadata: %w(payout_events status at by_id amount_minor_units currency paid_on reference note),
          excluded_pii: %w(
            donor_identity bank_account phone email address recipient_list member_list provider_payload
            odoo_payload raw_payment_payload public_export payout_note_public_view
          ),
          privacy_boundary: "Matched-giving payout notes and references are operator-private finance state, not public or aggregate analytics data.",
          enforcement: %w(admin_only validations finance_sop),
          tests: %w(
            test/models/decidim/bih/goodwill/match_request_test.rb
            test/integration/decidim/bih/admin/goodwill_dashboard_test.rb
          )
        },
        {
          id: "goodwill_transactions",
          owner: "engine",
          storage: "table:decidim_bih_goodwill_transactions",
          producer: "Decidim::Bih::Goodwill::Ledger",
          consumers: %w(wallet admin_goodwill analytics trends),
          stores: "Append-only balanced point movements with kind, reason, idempotency key and bounded source metadata.",
          stored_fields: %w(
            decidim_organization_id kind reason idempotency_key metadata created_at updated_at
          ),
          allowed_metadata: %w(
            action resource_gid volunteer_availability_id volunteer_opportunity_id volunteer_log_id
            contribution_offer_id contribution_need_id invitee_id hours reverses_transaction_id admin_reason
          ),
          excluded_pii: %w(
            vote_weight ranking_boost phone email address provider_payload payment_reference
            donor_identity recipient_list member_list raw_request_params public_export private_note
          ),
          privacy_boundary: "Goodwill ledger metadata may explain why points moved but must not turn points into vote power or contact storage.",
          enforcement: %w(append_only double_entry idempotency_key AwardDispatch),
          tests: %w(
            test/services/decidim/bih/goodwill/award_dispatch_test.rb
            test/services/decidim/bih/goodwill/earning_rules_test.rb
          )
        },
        {
          id: "governance_approval_attestations",
          owner: "engine",
          storage: "table:decidim_bih_governance_approval_attestations",
          producer: "Decidim::Bih::Governance::AttestationRecorder",
          consumers: %w(/admin/bih/governance release_governance_review operator_audit_review),
          stores: "Historical append-only proof for releases recorded while independent LFBN attestation was required; new releases use one exact administrator approval.",
          stored_fields: %w(
            decidim_organization_id governance_approval_id decidim_user_id operator_audit_event_id
            approval_role attested_at created_at updated_at
          ),
          excluded_pii: %w(
            raw_shell_history command_output raw_log_line token password secret api_key
            provider_payload backup_path dump_path database_url phone email address report_contact
            report_description recipient_list member_list ip_address user_agent status_token
          ),
          privacy_boundary: "Historical attestations store only actor and release-record references; release evidence remains bounded on the linked governance approval.",
          enforcement: %w(
            historical_records_only unique_governance_approval append_only
          ),
          tests: %w(
            test/models/decidim/bih/operator_and_partner_policy_test.rb
            test/integration/decidim/bih/admin/governance_controller_test.rb
            test/system/admin_governance_test.rb
          )
        },
        {
          id: "governance_approvals",
          owner: "engine",
          storage: "table:decidim_bih_governance_approvals",
          producer: "Decidim::Bih::Governance::ApprovalRecorder",
          consumers: %w(/admin/bih/governance operator_audit_review release_governance_review),
          stores: "Append-only owner/admin approval status, scope, actor, release SHAs and bounded evidence digest/summary.",
          stored_fields: %w(
            decidim_organization_id decidim_user_id operator_audit_event_id governance_kind
            approval_role status scope_key app_sha engine_sha evidence_summary evidence_digest
            approved_at metadata created_at updated_at
          ),
          allowed_metadata: %w(
            dry_run_status dry_run_total release_window recorded_from runbook smoke_status
          ),
          forbidden_metadata_keys: %w(
            address api_key authorization backup_path bearer body command_output contact
            credential database_url description dump_path email internal_note ip_address
            log_line message note params password payload phone private_key provider_payload
            raw raw_log recipient_list report_description request_ip response_body secret
            session_digest shell_history status_token token user_agent viber_id viber_sender
          ),
          excluded_pii: %w(
            raw_shell_history command_output raw_log_line token password secret api_key
            provider_payload backup_path dump_path database_url phone email address report_contact
            report_description recipient_list member_list ip_address user_agent status_token
          ),
          privacy_boundary: "Governance approvals prove an operational decision was reviewed without copying logs, " \
                            "credentials, provider payloads, private citizen data or backup locations into Decidim.",
          enforcement: %w(GovernanceApproval.sanitize_metadata SECRET_TEXT_PATTERN append_only admin_only_create),
          tests: %w(
            test/models/decidim/bih/operator_and_partner_policy_test.rb
            test/integration/decidim/bih/admin/governance_controller_test.rb
            test/system/admin_governance_test.rb
          )
        },
        {
          id: "integration_health",
          owner: "engine",
          storage: "redis:bih:integration_health",
          producer: "Decidim::Bih::IntegrationHealth",
          consumers: %w(/admin/bih/integrations ops_health_smoke),
          stores: "Per-provider and organization/global success/failure timestamps, bounded tallies and scrubbed error class/code.",
          stored_fields: %w(last_success_at last_error_at last_error_code last_error_class success_count failure_count status),
          allowed_metadata: %w(provider organization_id http_status error_code error_class success),
          excluded_pii: %w(
            raw_exception message phone email address provider_payload request_body response_body token
            api_key viber_sender report_description bot_prompt bot_reply_text
          ),
          privacy_boundary: "Integration health is advisory observability; it stores fixed scalar health fields and never serializes provider payloads.",
          enforcement: %w(TOPICS SafeErrorMetadata allowlisted_store_fields tally_cap stale_status redis_ttl),
          tests: %w(
            test/services/decidim/bih/integration_health_test.rb
            test/integration/decidim/bih/admin/integrations_controller_test.rb
          )
        },
        {
          id: "komsiluk_notice_publication",
          owner: "engine",
          storage: "tables:decidim_bih_komsiluk_posts+decidim_bih_komsiluk_post_revisions+decidim_bih_komsiluk_help_responses+decidim_bih_komsiluk_photo_drafts",
          producer: "Decidim::Bih::Komsiluk::PostCreator",
          consumers: %w(member_board author_corrections authorized_moderation private_notice_reference),
          stores: "Member-only notice content and private bounded revision, optional help and expiring normalized-photo evidence.",
          stored_fields: %w(origin content_revision publication_key published_at details notification_capture_identity snapshot expires_at),
          allowed_metadata: %w(origin content_revision publication_key source source_record activity moderation resolved_outcome),
          excluded_pii: %w(body title snapshot photo author_name help_nickname member_list recipient_list signed_photo_token),
          privacy_boundary: "Membership gates every board/media read. Help exposes a voluntary nickname to the notice author only. Revisions remain private. " \
                            "Closed/expired body retention also purges attachments, details, revisions and help rows; photo drafts expire after two hours.",
          enforcement: %w(organization_membership_scope private_media_controller normalized_upload expiring_owner_draft bounded_revisions explicit_help_consent retention_sweep),
          tests: %w(test/integration/decidim/bih/komsiluk_board_test.rb test/services/decidim_app/bijeljina/milica/read_port_test.rb)
        },
        {
          id: "komsiluk_phone_intents",
          owner: "engine",
          storage: "tables:decidim_bih_komsiluk_send_intents+decidim_bih_komsiluk_phone_deliveries+decidim_bih_komsiluk_sms_budgets",
          producer: "Decidim::Bih::Komsiluk::NoticeComposer",
          consumers: %w(exact_operator_preview notice_phone_dispatch provider_reconciliation aggregate_delivery_review privacy_retention),
          stores: "Encrypted exact publication/phone preview, private recipient request and provider outcome evidence, and aggregate daily SMS budget reservations.",
          stored_fields: %w(decidim_organization_id decidim_user_id publication_key preview_digest payload_ciphertext payload_scrubbed_at confirmed_at expires_at
                            platform_delivery_id status channels destination_digest provider_message_ids previous_attempts due_at attempted_at delivered_at reason
                            provider_checked_at provider_status budget_on currency reserved_minor budget_released_at),
          allowed_metadata: %w(source_revision content_revision urgency_reason channels template_digest audience_digest budget_limit expiry),
          excluded_pii: %w(title body sms_text phone email recipient_list member_list payload_ciphertext provider_message_ids destination_digest),
          privacy_boundary: "Only authorized operators can review their exact preview. Routine review is aggregate; recipient identities and provider routing remain private. " \
                            "The explicit cutoff cannot be newer than 90 days; unresolved accepted/unknown handoffs remain available for reconciliation. " \
                            "Budget rows contain aggregate amounts only.",
          enforcement: %w(encrypted_payload one_confirmation exact_audience_digest final_source_lock final_membership_check
                          unique_recipient_request concurrent_budget_reservation explicit_retention_cutoff),
          tests: %w(test/services/decidim/bih/komsiluk/notice_composer_test.rb test/jobs/decidim/bih/komsiluk_phone_delivery_job_test.rb)
        },
        {
          id: "komsiluk_post_reviews",
          owner: "engine",
          storage: "table:decidim_bih_komsiluk_post_reviews",
          producer: "Decidim::Bih::Komsiluk::PostModeration",
          consumers: %w(admin_komsiluk_post_review),
          stores: "Append-only content-free decisions with private reviewer reference, fixed reason, lifecycle transition and reviewed revision.",
          stored_fields: %w(decidim_organization_id decidim_bih_komsiluk_post_id reviewer_id action reason previous_status
                            resulting_status content_revision flagged_count created_at updated_at),
          allowed_metadata: %w(review_id reason previous_status restored_status content_revision),
          excluded_pii: %w(body title flagger_name flagger_id member_list recipient_list phone email address provider_payload),
          privacy_boundary: "Scoped moderators can review only assigned boards. Decisions retain no post text or flagger list; " \
                            "they cascade with the post and reviewer references nullify on account-row deletion.",
          enforcement: %w(PostModeration ModerationAccess OperatorAuthorization fixed_reason_codes organization_scoping row_lock optimistic_version foreign_keys),
          tests: %w(test/integration/decidim/bih/admin/komsiluk_posts_controller_test.rb)
        },
        {
          id: "komsiluk_broadcasts",
          owner: "engine",
          storage: "table:decidim_bih_broadcasts",
          producer: "Decidim::Bih::KomsilukBroadcast",
          consumers: %w(admin_broadcasts komsiluk_activity_review trends),
          stores: "One immutable operator broadcast row with area, sender, message, channels and aggregate recipient count.",
          stored_fields: %w(
            decidim_organization_id local_area_id sent_by_id message channels recipients_count
            created_at updated_at
          ),
          allowed_metadata: %w(channels recipients_count area_id area_kind),
          excluded_pii: %w(
            recipient_list member_list recipient_phone recipient_email viber_sender delivery_payload
            delivery_response ip_address user_agent hidden_profile_data
          ),
          privacy_boundary: "Broadcast audit rows may keep operator-authored message text, but never recipient identities or delivery payloads.",
          enforcement: %w(aggregate_preview MembershipResolver recipient_id_chunks),
          tests: %w(
            test/services/decidim/bih/komsiluk_broadcast_test.rb
            test/integration/decidim/bih/admin/broadcasts_controller_test.rb
          )
        },
        {
          id: "komsiluk_naming_campaign_report",
          owner: "host",
          storage: "derived_json:DecidimApp::Bijeljina::KomsilukNamingCampaignMetrics",
          producer: "DecidimApp::Bijeljina::KomsilukNamingCampaignMetrics",
          consumers: %w(decidim_app:komsiluk_naming_campaign:report operator_campaign_prize_review),
          stores: "Per-Komšiluk aggregate campaign eligibility, proposal and vote counts plus aggregate community and personal prize shortlists.",
          stored_fields: %w(
            process_slug generated_at primary_kpi totals areas area_slug area_name assigned_members
            sms_verified_members citizen_proposals final_votes unique_voters verified_active_participants
            community_prize_leaders personal_prize_shortlist proposal_id title votes citizen_authored vote_share
          ),
          allowed_metadata: %w(area_slug area_name proposal_id title citizen_authored aggregate_counts vote_share),
          excluded_pii: %w(
            decidim_user_id user_id user_name nickname email phone phone_hash address coordinates
            komsiluk_membership_record member_list recipient_list sms_metadata authorization_metadata
            ip_address user_agent raw_request_params provider_payload
          ),
          privacy_boundary: "Naming-campaign prize review derives only aggregate eligible activity and public proposal references; " \
                            "it never emits citizen identities, membership rows, verification metadata or contact/location data.",
          enforcement: %w(
            organization_scope assigned_profile_intersection sms_authorization_intersection
            aggregate_sets no_member_ids minimum_personal_prize_electorate
          ),
          tests: %w(
            test/services/decidim_app/bijeljina/komsiluk_naming_campaign_metrics_test.rb
            test/services/decidim_app/bijeljina/komsiluk_naming_campaign_policy_test.rb
          )
        },
        {
          id: "operator_audit_events",
          owner: "engine",
          storage: "table:decidim_bih_operator_audit_events",
          producer: "Decidim::Bih::OperatorAuditEvent.record!",
          consumers: %w(/admin/bih/operator-audit operator_role_review),
          stores: "Append-only operator action type, actor, role, permission, resource identity and sanitized bounded metadata.",
          stored_fields: %w(
            decidim_organization_id decidim_user_id role permission event_type resource_type
            resource_id occurred_at metadata created_at updated_at
          ),
          allowed_metadata: %w(
            role user_id recipient_id context_type context_id subject_length body_length
            status from_status to_status hours opportunity_id points owner_type owner_id
            expires_on amount_minor_units currency paid_on selected_count eligible_count current_note_present
            reason_present already action kind resource_gid source series_key updated_count
            skipped_count fields governance_kind governance_approval_id scope_key evidence_digest
            private_reason evidence_reviewed
          ),
          forbidden_metadata_keys: %w(
            address body contact description email internal_note message note params payload phone
            provider_payload raw recipient_list report_description request_ip session_digest
            status_token user_agent viber_id viber_sender
          ),
          excluded_pii: %w(
            message_body operator_note report_description report_address report_contact phone email
            viber_identifier whatsapp_identifier messenger_identifier instagram_identifier
            recipient_list member_list provider_payload raw_request_params
            internal_note_body status_token ip_address user_agent
          ),
          privacy_boundary: "Operator audit rows prove privileged actions happened without copying the sensitive content those actions touched. " \
                            "Cancellation and reversal reasons are private, bounded, contact/credential-redacted operator rationales.",
          enforcement: %w(OperatorAuditEvent.sanitize_metadata PrivateActionReason FORBIDDEN_METADATA_KEYS admin_only),
          tests: %w(
            test/models/decidim/bih/operator_audit_event_test.rb
            test/services/decidim/bih/admin/private_action_reason_test.rb
            test/integration/decidim/bih/admin/operator_roles_controller_test.rb
          )
        },
        {
          id: "operator_messages",
          owner: "engine",
          storage: "table:decidim_bih_operator_messages",
          producer: "Decidim::Bih::OperatorMessenger",
          consumers: %w(decidim_notifications /admin/bih/messages operator_message_review),
          stores: "Decidim-only support message subject/body, sender, recipient, context identity and sent timestamp.",
          stored_fields: %w(
            decidim_organization_id sender_id recipient_id subject body context_type context_id
            sent_at metadata created_at updated_at
          ),
          allowed_metadata: %w(context_type context_id),
          excluded_pii: %w(
            phone email address viber_sender provider_payload recipient_list external_delivery_payload
            raw_request_params contact_export
          ),
          privacy_boundary: "Operator messages intentionally store the message text for the recipient, but delivery stays inside Decidim and does not expose contact channels.",
          enforcement: %w(operator_message_send Decidim::EventsManager in_app_only),
          tests: %w(
            test/models/decidim/bih/operator_message_test.rb
            test/services/decidim/bih/operator_messenger_test.rb
          )
        },
        {
          id: "partner_notices",
          owner: "engine",
          storage: "table:decidim_bih_partner_notices",
          producer: "Decidim::Bih::PartnerNotice",
          consumers: %w({public_mount}/organizacija/:id organization_profiles),
          stores: "Public organization notice title/body, author, notice type, publication and expiry timestamps.",
          stored_fields: %w(
            decidim_organization_id partner_profile_id author_id title body notice_type
            published_at expires_at created_at updated_at
          ),
          allowed_metadata: %w(notice_type published_at expires_at),
          excluded_pii: %w(
            private_contact_email private_contact_phone recipient_list member_list provider_payload
            raw_request_params hidden_member_note
          ),
          privacy_boundary: "Notices are public content from verified organizations; private organization contacts and delivery details stay outside notices.",
          enforcement: %w(verified_profile official_notice_requires_official_publisher public_content_review),
          tests: %w(
            test/models/decidim/bih/partner_notice_test.rb
            test/integration/decidim/bih/organizations_controller_test.rb
          )
        },
        {
          id: "partner_profiles",
          owner: "engine",
          storage: "table:decidim_bih_partner_profiles",
          producer: "Decidim::Bih::PartnerProfile",
          consumers: %w({public_mount}/organizacije {public_mount}/organizacija/:id /admin/bih/organizations),
          stores: "Organization type, public profile fields, verification state, legacy group link and admin-only private contact fields.",
          stored_fields: %w(
            decidim_organization_id display_name legal_name slug kind verification_status
            public_description logo website local_area_id private_contact_name private_contact_email
            private_contact_phone verified_by_id verified_at rejected_at rejection_reason
            legacy_user_group_id metadata created_at updated_at
          ),
          allowed_metadata: %w(legacy_user_group_id source),
          excluded_pii: %w(
            private_contact_name private_contact_email private_contact_phone rejection_private_note
            member_private_note phone email address provider_payload raw_request_params
          ),
          privacy_boundary: "Only verified public organization fields and accepted member names are public; private contacts are admin-only verification data.",
          enforcement: %w(verified_public_scope admin_only_private_contacts public_membership_transparency),
          tests: %w(
            test/models/decidim/bih/partner_profile_test.rb
            test/integration/decidim/bih/admin/partner_profiles_controller_test.rb
            test/integration/decidim/bih/organizations_controller_test.rb
          )
        },
        {
          id: "partner_impact_summary",
          owner: "engine",
          storage: "derived_view:Decidim::Bih::PartnerImpactSummary",
          producer: "Decidim::Bih::PartnerImpactSummary",
          consumers: %w(public_partner_profile community_project_partner_attribution),
          stores: "Public organization-level counts for approved projects, LFBN-recognized non-cash contributions, " \
                  "hosted volunteer opportunities, verified hours and bounded recognition labels.",
          stored_fields: %w(
            approved_projects approved_needs fulfilled_needs confirmed_offers hosted_opportunities
            verified_volunteer_hours volunteer_participants recognition_labels
          ),
          allowed_metadata: %w(recognition_labels aggregate_counts aggregate_hours),
          excluded_pii: %w(
            user_name employee_name employee_list member_list volunteer_identity donor_identity
            payment_reference phone email address offer_note attendance_note provider_payload recipient_list
          ),
          privacy_boundary: "Organization recognition is aggregate and non-transferable; it never publishes worker identities " \
                            "or claims that an organization donated cash from Odoo aggregate data.",
          enforcement: %w(aggregate_queries recognized_only no_member_join no_cash_donor_inference),
          tests: %w(
            test/services/decidim/bih/partner_impact_summary_test.rb
            test/integration/decidim/bih/organizations_controller_test.rb
          )
        },
        {
          id: "privacy_retention_runs",
          owner: "engine",
          storage: "table:decidim_bih_privacy_retention_runs",
          producer: "Decidim::Bih::Privacy::RetentionSweep",
          consumers: %w(/admin/bih/privacy-retention ops_health_smoke monthly_maintenance),
          stores: "Durable sweep status, dry-run flag, aggregate bucket counts, cutoffs and sanitized failure metadata.",
          stored_fields: %w(
            decidim_organization_id status dry_run source started_at finished_at total counts cutoffs
            error_class error_message created_at updated_at
          ),
          allowed_metadata: %w(counts cutoffs error_class error_message),
          excluded_pii: %w(
            report_contact report_description report_address report_photo viber_sender volunteer_free_text
            komsiluk_post_body raw_log_line sql_statement backtrace request_params provider_payload
          ),
          privacy_boundary: "Retention history proves lifecycle work happened without copying the data it is meant to expire.",
          enforcement: %w(SafeErrorMetadata aggregate_counts durable_run_history),
          tests: %w(
            test/services/decidim/bih/privacy/retention_sweep_test.rb
            test/system/admin_privacy_retention_test.rb
          )
        },
        {
          id: "homepage_public_activity",
          owner: "engine",
          storage: "derived_view:Decidim::Bih::HomepageActivity",
          producer: "Decidim::Bih::HomepageActivity",
          consumers: %w(/),
          stores: "No persistence; public report references/statuses, approved open volunteer titles, verified organization names and published notice titles.",
          stored_fields: %w(kind title path created_at),
          allowed_metadata: %w(public_reference public_status publication_time),
          excluded_pii: %w(report_description report_contact report_author status_token coordinates photo private_contact member_list komsiluk_post_title komsiluk_post_body),
          privacy_boundary: "Same public audience for guests and members; never read Komšiluk posts or report private fields. Recheck public visibility on each render.",
          enforcement: %w(organization_scope publicly_visible published explicit_field_selection),
          tests: %w(test/integration/decidim_app/homepage_public_activity_test.rb)
        },
        {
          id: "public_impact_summary",
          owner: "engine",
          storage: "derived_view:Decidim::Bih::ImpactSummary",
          producer: "Decidim::Bih::ImpactSummary",
          consumers: %w({public_mount}/uticaj),
          stores: "Public aggregate report, donation, Goodwill, volunteering, Komšiluk, MZ-level and organization-wide trend impact counts.",
          stored_fields: %w(metric trend_key current previous delta aggregate_count aggregate_total mz_slug status category sparse_suppression),
          allowed_metadata: %w(status category mz_slug trend_key),
          excluded_pii: %w(
            donor_identity payment_reference report_contact report_description report_coordinates
            volunteer_free_text user_name nickname phone email viber_identifier whatsapp_identifier
            messenger_identifier instagram_identifier payout_reference
            komsiluk_post_title komsiluk_post_body member_list recipient_list
          ),
          privacy_boundary: "Public impact output must stay aggregate, use whitelisted organization-wide trend metrics and suppress sparse local-area cells.",
          enforcement: %w(sparse_cell_suppression public_trend_metric_whitelist aggregate_queries public_surface_manifest),
          tests: %w(
            test/services/decidim/bih/impact_summary_test.rb
            test/integration/decidim/bih/impact_dashboard_test.rb
          )
        },
        {
          id: "report_dispatch_private_content",
          owner: "engine",
          storage: "table:decidim_bih_report_dispatches",
          producer: "Decidim::Bih::ReportDispatching",
          consumers: %w(report_review_workspace privacy_retention),
          stores: "Encrypted approved outbound mail and private reconciliation evidence beside durable sending metadata.",
          stored_fields: %w(
            report_id approved_by_id kind state input_digest deduplication_key snapshot_ciphertext message_id error_class started_at accepted_at
            reconciled_at reconciled_by_id reconciliation_evidence data_redacted_at created_at updated_at
          ),
          allowed_metadata: %w(kind state accepted_at data_redacted_at),
          excluded_pii: %w(snapshot_ciphertext reconciliation_evidence body contact message_id),
          privacy_boundary: "Immutable approval snapshot; decrypted only for authorized case review and sending. Retention removes finished content, preserving audit metadata.",
          enforcement: %w(encrypted_snapshot actor_tenant_permission report_lock ReportReviewRetention),
          tests: %w(test/integration/decidim/bih/report_review_account_privacy_test.rb test/services/decidim/bih/privacy/report_review_retention_test.rb)
        },
        {
          id: "report_review_private_proposals",
          owner: "engine",
          storage: "table:decidim_bih_report_review_proposals",
          producer: "Decidim::Bih::ReportReviewAssistant",
          consumers: %w(report_review_workspace privacy_retention),
          stores: "Encrypted AI suggestion with source version and separate human adoption/correction metadata.",
          stored_fields: %w(
            report_id input_digest prompt_version state model error_code proposal_ciphertext finished_at decided_by_id decided_at approved_action
            changed_fields data_redacted_at created_at updated_at
          ),
          allowed_metadata: %w(state error_code approved_action changed_fields),
          excluded_pii: %w(proposal_ciphertext facts quotes question forwarding_note),
          privacy_boundary: "A proposal is private evidence, not an authorized action. It is never a standard citizen export entity; redacted proposals cannot be adopted.",
          enforcement: %w(encrypted_proposal strict_schema version_checks human_confirmation ReportReviewRetention),
          tests: %w(test/integration/decidim/bih/report_review_account_privacy_test.rb test/services/decidim/bih/privacy/report_review_retention_test.rb)
        },
        {
          id: "report_review_private_drafts",
          owner: "engine",
          storage: "table:decidim_bih_reports.review_draft",
          producer: "Decidim::Bih::ReportDecision",
          consumers: %w(report_review_workspace privacy_retention),
          stores: "Versioned human decision draft, including private free text, saved without executing it.",
          stored_fields: %w(review_draft),
          allowed_metadata: %w(saved_at),
          excluded_pii: %w(values body internal_note contact ai_proposal_id),
          privacy_boundary: "Staff draft content stays private and is excluded from public and standard citizen exports. Existing case retention removes inactive drafts.",
          enforcement: %w(operator_authorization version_checks ReportReviewRetention),
          tests: %w(test/integration/decidim/bih/report_review_account_privacy_test.rb test/services/decidim/bih/privacy/report_review_retention_test.rb)
        },
        {
          id: "report_photo_draft_storage",
          owner: "engine",
          storage: "table:decidim_bih_report_photo_drafts+active_storage",
          producer: "Decidim::Bih::ReportPhotoDraft",
          consumers: %w(report_review_workspace privacy_retention),
          stores: "Normalized temporary photo with organization/session ownership and short-lived signed access.",
          stored_fields: %w(organization_id consumed_report_id owner_digest expires_at created_at updated_at),
          allowed_metadata: %w(expires_at),
          excluded_pii: %w(owner_digest token photo blob_key filename),
          privacy_boundary: "Session-owned, not a user profile/export entity. Access expires after two hours; " \
                            "purge jobs remove temporary content without deleting a consumed report photo.",
          enforcement: %w(session_org_binding signed_expiry row_lock ImageNormalizer expiry_job daily_recovery),
          tests: %w(test/integration/decidim/bih/report_review_account_privacy_test.rb test/services/decidim/bih/privacy/report_review_retention_test.rb)
        },
        {
          id: "report_events",
          owner: "engine",
          storage: "table:decidim_bih_report_events",
          producer: "Decidim::Bih::Report#record_event!",
          consumers: %w(/admin/bih/reports/:reference report_triage),
          stores: "Append-only report lifecycle event type, source, actor role, timestamp and sanitized bounded metadata.",
          stored_fields: %w(
            decidim_bih_report_id decidim_organization_id decidim_user_id event_type source
            actor_role occurred_at metadata created_at updated_at
          ),
          allowed_metadata: %w(
            anonymous has_photo has_location has_contact locale category severity department needs_review
            status from_status to_status forwarded_at error_class error_code failure_count
            previous_failure_count previous_error_code had_failure reason duplicate_of_reference
            previous_duplicate_of_reference previous_note_present current_note_present sistem48_status
            proposal_id lease job_id prompt_version
          ),
          forbidden_metadata_keys: %w(
            address ai_summary contact coordinates description internal_note latitude longitude params
            payload photo_url reporter_contact reporter_email reporter_phone request_ip status_note user_agent
          ),
          excluded_pii: %w(
            reporter_name reporter_email reporter_phone address coordinates description internal_note_body
            status_note_body ai_summary photo_url raw_forwarder_payload raw_provider_response ip_address user_agent
          ),
          privacy_boundary: "Report events explain lifecycle and forwarding state without duplicating citizen report content.",
          enforcement: %w(ReportEvent.sanitize_metadata append_only FORBIDDEN_METADATA_KEYS),
          tests: %w(
            test/models/decidim/bih/report_event_test.rb
            test/services/decidim/bih/report_intake_test.rb
            test/services/decidim/bih/report_processing_test.rb
            test/integration/decidim/bih/admin/reports_controller_test.rb
          )
        },
        {
          id: "report_runtime_state",
          owner: "engine",
          storage: "table:decidim_bih_reports",
          producer: "Decidim::Bih::Report",
          consumers: %w(public_report_tracker admin_reports report_triage),
          stores: "PII-free status history and sanitized forwarding failure class/code/count/timestamp beside the raw report row.",
          stored_fields: %w(
            status status_history forwarding_error_class forwarding_error_code forwarding_failure_count
            forwarding_failed_at forwarded_at sistem48_status sistem48_synced_at status_token
          ),
          allowed_metadata: %w(status at forwarding_error_class forwarding_error_code forwarding_failure_count sistem48_status),
          excluded_pii: %w(
            reporter_email reporter_phone address coordinates description ai_summary internal_note
            forwarding_error_message reporter_contact photo_url provider_payload status_token
          ),
          privacy_boundary: "Runtime state beside the report may drive lifecycle views; status tokens are private link credentials and must not appear in public/admin aggregates.",
          enforcement: %w(status_history_append SafeErrorMetadata public_tracker_pii_light),
          tests: %w(
            test/models/decidim/bih/report_test.rb
            test/models/decidim/bih/report_event_test.rb
            test/integration/decidim/bih/reports_show_test.rb
            test/mailers/decidim/bih/reporter_mailer_test.rb
            test/services/decidim/bih/report_processing_test.rb
            test/integration/decidim/bih/reports_intake_test.rb
          )
        },
        {
          id: "report_push_claim_state",
          owner: "engine",
          storage: "table:decidim_notifications.extra",
          producer: "Decidim::Bih::Report#notify_reporter_of_status_change",
          consumers: %w(messaging_reconciliation),
          stores: "A bounded uncertainty marker on an existing private report-status inbox notification after a push claim cannot be classified as queued or absent.",
          stored_fields: %w(mi_report_push_claim),
          allowed_metadata: %w(mi_report_push_claim),
          excluded_pii: %w(report_description status_token email phone push_endpoint provider_payload raw_error),
          privacy_boundary: "Reconciliation counts historical uncertainty since the requested start time; it does not expose account identities or " \
                            "authorize a duplicate fallback. The marker shares the notification's existing lifecycle.",
          enforcement: %w(tenant_scoped_aggregate no_replay_on_uncertainty),
          tests: %w(rails_test/report_status_claim_test.rb)
        },
        {
          id: "reward_fulfillment_events",
          owner: "engine",
          storage: "table:decidim_bih_goodwill_reward_fulfillment_events",
          producer: "Decidim::Bih::Goodwill::RewardFulfillment#record_event!",
          consumers: %w(admin_goodwill reward_fulfillment_review),
          stores: "Append-only reward handover event type, source, actor role, timestamp and sanitized status metadata.",
          stored_fields: %w(
            decidim_bih_goodwill_reward_fulfillment_id decidim_organization_id decidim_user_id
            event_type source actor_role occurred_at metadata created_at updated_at
          ),
          allowed_metadata: %w(
            from_status to_status reward_key cost ledger_transaction_id action selected_count
            eligible_count reversal_transaction_id private_reason
          ),
          forbidden_metadata_keys: %w(
            address contact email fulfillment_note message note params payload phone pickup_location
            provider_payload recipient request_ip user_agent viber_id
          ),
          excluded_pii: %w(
            citizen_name citizen_email citizen_phone address pickup_note pickup_location notification_body
            provider_payload delivery_payload request_ip user_agent viber_identifier
          ),
          privacy_boundary: "Reward events show operational handover state without storing citizen contact or pickup details. " \
                            "Cancellation reasons are private, bounded, contact/credential-redacted operator rationales.",
          enforcement: %w(RewardFulfillmentEvent.sanitize_metadata PrivateActionReason append_only FORBIDDEN_METADATA_KEYS),
          tests: %w(
            test/models/decidim/bih/goodwill/reward_fulfillment_event_test.rb
            test/models/decidim/bih/goodwill/reward_fulfillment_test.rb
            test/integration/decidim/bih/admin/goodwill_dashboard_test.rb
          )
        },
        {
          id: "viber_inbound_deliveries",
          owner: "engine",
          storage: "table:decidim_bih_viber_inbound_deliveries",
          producer: "Decidim::Bih::Viber::InboundDelivery",
          consumers: %w(
            DecidimApp::Viber::ProcessInboundDeliveryJob DecidimApp::Infobip::ProcessInboundDeliveryJob
            DecidimApp::Viber::RecoverInboundDeliveriesJob Decidim::Bih::Admin::ChatHealthSummary
          ),
          stores: "A tenant- and channel-scoped provider-id digest plus encrypted bounded message/effect envelopes; " \
                  "effect payload slots keep shorter deadlines while PII-free replay metadata remains for seven days or less.",
          stored_fields: %w(
            decidim_organization_id channel provider_message_key sender_digest encrypted_payload encrypted_effects
            state phase attempts effects_cursor effects_count error_class received_at processed_at expires_at
            next_effect_scrub_at lock_version created_at updated_at
          ),
          allowed_metadata: %w(
            channel state phase attempts effects_cursor effects_count error_class received_at processed_at expires_at
            next_effect_scrub_at
          ),
          excluded_pii: %w(
            raw_provider_message_id raw_sender raw_message_text raw_media_url raw_coordinates webhook_payload
            provider_payload phone email address viber_identifier whatsapp_identifier messenger_identifier
            instagram_identifier contact_name username referral_metadata recipient_list token api_key
            error_message backtrace
          ),
          privacy_boundary: "The encrypted envelopes contain only processing primitives and allowlisted external-effect descriptors, " \
                            "use separate encryption purposes, and completed or due slots become payload-free tombstones; " \
                            "the receipt is deleted after a fixed seven-day retry window; raw provider/contact payloads are never serialized, " \
                            "and job and log payloads contain only the row id.",
          enforcement: %w(
            organization_channel_message_unique_index MessageEncryptor channel_domain_separated_provider_id_digest
            purpose_separated_effect_envelope bounded_primitives allowlisted_durable_effects
            per_effect_deadline five_minute_effect_scrub payload_free_tombstone
            claim_generation_fence exact_cursor_compare_and_set job_id_only clear_on_success
            seven_day_ttl bounded_attempts no_error_message
          ),
          tests: %w(
            test/services/decidim/bih/durable_effects_test.rb
            test/models/decidim/bih/viber/inbound_delivery_test.rb
            test/integration/decidim_app/viber/webhook_test.rb
            test/integration/decidim_app/infobip/webhook_test.rb
            test/jobs/decidim_app/viber/recover_inbound_deliveries_job_test.rb
          )
        },
        {
          id: "viber_reply_queue",
          owner: "engine",
          storage: "active_job:integrations:viber_encrypted_payload",
          producer: "Decidim::Bih::Infobip::SendViberTextJob+SendViberImageJob",
          consumers: %w(ActiveJob Sidekiq Decidim::Bih::Infobip::Client),
          stores: "One authenticated ciphertext whose plaintext is a bounded Viber Bot reply or sticker envelope with a deadline no later than 23 hours after enqueue.",
          stored_fields: %w(encrypted_payload),
          allowed_metadata: %w(job_class queue_name attempts error_class http_status error_code error_group),
          excluded_pii: %w(
            plaintext_job_arguments raw_recipient raw_reply_text viber_identifier sticker provider_payload
            provider_response error_message
          ),
          privacy_boundary: "ActiveJob and failed-job metadata receive ciphertext only; the opaque Viber recipient, reply text, " \
                            "optional sticker and expiry are decrypted inside the worker. Delivery diagnostics retain only " \
                            "numeric HTTP status and bounded provider code/group.",
          enforcement: %w(
            MessageEncryptor isolated_key_and_purpose ciphertext_only_job_arguments log_arguments_false
            before_enqueue serialize_defense configured_job_scheduling expiry_inside_envelope
            session_reply_ttl_23_hours safe_delivery_error
            allowlisted_provider_error_metadata
          ),
          tests: %w(
            test/jobs/decidim/bih/infobip/send_viber_reply_jobs_test.rb
            test/services/decidim/bih/infobip/client_test.rb
            test/services/decidim/bih/infobip/error_test.rb
          )
        },
        {
          id: "viber_session_state_cache",
          owner: "engine",
          storage: "redis:bih:viber:state/<organization>/<hmac>",
          producer: "Decidim::Bih::Concierge::SessionStore",
          consumers: %w(Decidim::Bih::Concierge::Responder),
          stores: "One bounded Viber flow-state value for 10 minutes plus at most one five-minute scrub interval; " \
                  "a pending Komšiluk category choice may include citizen-supplied post text.",
          stored_fields: %w(organization_id hmac_sender_digest state ttl_seconds),
          allowed_metadata: %w(state_type ttl_seconds),
          excluded_pii: %w(
            raw_sender sender_in_cache_key viber_identifier provider_contact_name provider_contact_phone
            provider_contact_email raw_coordinates media_url provider_payload webhook_payload otp_code api_key token
          ),
          privacy_boundary: "Short-lived state can contain text a citizen voluntarily types for a pending Komšiluk post; Redis expiry is " \
                            "10 minutes and a captured undelivered slot is scrubbed within the five-minute recovery cadence. " \
                            "The Redis key uses a tenant- and purpose-separated HMAC, " \
                            "never the raw Viber identity; no durable conversation row is created.",
          enforcement: %w(
            hmac_identity_key no_raw_sender_in_key bounded_state redis_ttl_10_minutes
            effect_deadline five_minute_effect_scrub payload_free_tombstone no_database_transcript
          ),
          tests: %w(
            test/services/decidim/bih/concierge/session_store_test.rb
            test/services/decidim/bih/concierge/responder_test.rb
          )
        },
        {
          id: "volunteer_attendance",
          owner: "engine",
          storage: "tables:decidim_bih_volunteer_signups+decidim_bih_volunteer_attendances",
          producer: "Decidim::Bih::ReviewVolunteerApplication+ConfirmVolunteerAttendance",
          consumers: %w(/admin/bih/volunteering operator_attendance_qr volunteering_roster),
          stores: "Application and seat decision history, first session date, plus dated presence decisions. Old signup attendance timestamps remain historical.",
          stored_fields: %w(
            decidim_organization_id decidim_bih_volunteer_opportunity_id decidim_user_id
            status attendance_confirmed_at attendance_source attendance_confirmed_by_id
            review_status review_source reviewed_at reviewed_by_id decision_reason queued_at first_session_at participation_ended_at
            decidim_bih_volunteer_signup_id work_date confirmed_at confirmed_by_id source
            created_at updated_at
          ),
          allowed_metadata: %w(
            attendance_source attendance_confirmed_at attendance_confirmed_by_id signup_id
            opportunity_id user_id status review_status review_source previous_status outcome work_date
          ),
          excluded_pii: %w(
            availability interests phone email address viber_sender raw_qr_token feedback_token
            private_evidence recipient_list member_list user_agent ip_address raw_application_text
          ),
          privacy_boundary: "Decisions retain only bounded user-visible reasons and dates. Dated attendance never stores availability, " \
                            "contact data, raw QR tokens or private evidence; audit metadata records status changes, not reason text.",
          enforcement: %w(VolunteerAttendanceToken ConfirmVolunteerAttendance ReviewVolunteerApplication operator_permission csrf_post no_get_write),
          tests: %w(
            test/integration/decidim/bih/admin/volunteering_controller_test.rb
            test/services/decidim/bih/admin/volunteering_roster_test.rb
          )
        }
      ].sort_by { |stream| stream.fetch(:id) }.freeze

      REQUIRED_EXCLUSION_TERMS = %w(
        address bot_reply_text donor_identity email member_list phone provider_payload
        raw_citizen_message recipient_list report_description session_digest user_name
        whatsapp_identifier messenger_identifier instagram_identifier
      ).freeze

      module_function

      def retention_buckets
        RETENTION_BUCKETS
      end

      # The buckets that Decidim::Bih::Privacy::RetentionSweep actually sweeps,
      # i.e. those that take a cutoff from the caller.
      #
      # Pending registrations have a separate fixed seven-day lifecycle and
      # remain in the audit inventory without claiming a RetentionSweep cutoff.
      # Only explicitly supported cutoff entries reach the monthly dashboard,
      # governance preview, and sweep task.
      #
      # This is THE source of truth for the sweep bucket set. The sweep service,
      # its job, the rake task and the admin dashboard all derive from it rather
      # than restating it, so a new bucket cannot be registered in one place and
      # silently missing from another.
      def sweep_buckets
        @sweep_buckets ||= RETENTION_BUCKETS.select { |bucket| bucket[:service_cutoff_key].present? }.freeze
      end

      # Bucket ids, in declaration order — the admin dashboard's row set.
      def sweep_bucket_ids
        @sweep_bucket_ids ||= sweep_buckets.map { |bucket| bucket.fetch(:id).to_sym }.freeze
      end

      # Keyword names accepted by RetentionSweep, e.g. :report_contact_before.
      def sweep_cutoff_keys
        @sweep_cutoff_keys ||= sweep_buckets.map { |bucket| bucket.fetch(:service_cutoff_key).to_sym }.uniq.freeze
      end

      # ENV var name => RetentionSweep keyword, for the rake entry point.
      def sweep_env_cutoffs
        @sweep_env_cutoffs ||= sweep_buckets.to_h do |bucket|
          [bucket.fetch(:env_cutoff_key), bucket.fetch(:service_cutoff_key).to_sym]
        end.freeze
      end

      def audit_event_streams(public_mount_path: Decidim::Bih.public_mount_path)
        AUDIT_EVENT_STREAMS.map do |stream|
          next stream unless stream.fetch(:id) == "public_impact_summary"

          stream.merge(
            consumers: stream.fetch(:consumers).map do |consumer|
              expand_public_mount_token(consumer, public_mount_path)
            end
          )
        end
      end

      def manifest(public_mount_path: Decidim::Bih.public_mount_path)
        {
          version: 1,
          retention_buckets: retention_buckets,
          audit_event_streams: audit_event_streams(public_mount_path:),
          required_exclusion_terms: REQUIRED_EXCLUSION_TERMS,
          review_rule: "Any new durable audit, analytics, retention or public impact row must declare stored fields, allowed metadata, excluded PII and tests before launch."
        }
      end

      def expand_public_mount_token(value, public_mount_path)
        mount = Decidim::Bih.normalize_public_mount_path(public_mount_path)
        value.sub("{public_mount}", mount == "/" ? "" : mount)
      end
    end
  end
end
