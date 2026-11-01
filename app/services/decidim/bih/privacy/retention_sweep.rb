# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Privacy
      # Disabled-by-default privacy lifecycle helper. Operators pass explicit
      # cutoffs after policy approval; nil cutoffs are no-ops. Dry-run is the
      # default so production checks can return counts without mutating data.
      class RetentionSweep
        OPERATOR_MESSAGE_BODY_REDACTION = "[body removed by privacy retention]"
        GovernanceApprovalRequired = Class.new(StandardError)

        Result = Struct.new(:dry_run, :counts, :run, keyword_init: true) do
          def total = counts.values.sum
        end

        class << self
          def call(**)
            new(**).call
          end

          # Live operational entry points use this wrapper. It re-runs the
          # approved dry-run immediately before mutation and refuses execution
          # when the approval is missing, stale, blocked, or bound to a
          # different aggregate total.
          def authorized_live_call(**attributes)
            organization = attributes.fetch(:organization)
            preview = call(**attributes, dry_run: true, record_run: false)
            approval = Decidim::Bih::GovernanceApproval.current_for(organization, "privacy_retention")
            approved_total = approval&.metadata.to_h["dry_run_total"]
            expected_scope = retention_scope_key(attributes)
            unless approval && approved_total.present? && approved_total.to_i == preview.total && approval.scope_key == expected_scope
              error = GovernanceApprovalRequired.new(
                "Current privacy-retention approval for this dry-run total is required"
              )
              record_blocked_live_attempt(attributes, preview, error)
              raise error
            end

            call(**attributes, dry_run: false)
          end

          # Public so the admin approval screen, cron wrapper, and live
          # executor bind to exactly the same set of cutoffs. The value is a
          # digest of named cutoff timestamps and applicable precision; it never
          # carries retained data or counts.
          def scope_key(**attributes)
            retention_scope_key(attributes)
          end

          private

          def retention_scope_key(attributes)
            cutoffs = attributes.each_with_object({}) do |(key, value), result|
              next unless key.to_s.end_with?("_before") && value.present?

              time = value.is_a?(Time) || value.is_a?(DateTime) ? value.to_time : Time.zone.parse(value.to_s)
              raise ArgumentError, "Invalid retention cutoff" unless time

              result[key.to_s] = time.utc.iso8601(6)
            end
            if cutoffs.has_key?("report_coordinates_before") && attributes[:report_coordinate_precision].present?
              cutoffs["report_coordinate_precision"] = attributes[:report_coordinate_precision].to_i
            end
            "retention:v2:#{Digest::SHA256.hexdigest(cutoffs.sort.to_h.to_json)}"
          end

          def record_blocked_live_attempt(attributes, preview, error)
            return unless attributes.fetch(:record_run, true)

            run = Decidim::Bih::Privacy::RetentionRun.create!(
              organization: attributes.fetch(:organization),
              dry_run: false,
              source: attributes.fetch(:run_source, "service").to_s[0, 64],
              status: "running",
              started_at: Time.current,
              cutoffs: retention_run_cutoffs(attributes),
              counts: preview.counts.transform_keys(&:to_s),
              total: preview.total
            )
            run.fail!(error)
          rescue StandardError => e
            Rails.logger.error(
              "[Privacy::RetentionSweep] could not persist blocked live attempt: #{e.class}"
            )
          end

          def retention_run_cutoffs(attributes)
            attributes.each_with_object({}) do |(key, value), cutoffs|
              next unless key.to_s.end_with?("_before") || key.to_s == "report_coordinate_precision"
              next if value.blank?

              cutoffs[key.to_s] = if key.to_s.end_with?("_before")
                                    Time.zone.parse(value.to_s).utc.iso8601
                                  else
                                    value.to_i
                                  end
            rescue ArgumentError
              cutoffs[key.to_s] = value.to_s
            end
          end
        end

        # rubocop:disable Metrics/ParameterLists
        def initialize(organization:, dry_run: true,
                       report_contact_before: nil,
                       report_review_before: nil,
                       report_photo_before: nil,
                       report_coordinates_before: nil,
                       report_coordinate_precision: nil,
                       citizen_phone_before: nil,
                       viber_linkage_before: nil,
                       viber_business_contact_before: nil,
                       volunteer_availability_before: nil,
                       komsiluk_post_body_before: nil,
                       komsiluk_delivery_before: nil,
                       chat_feedback_before: nil,
                       partner_private_contact_before: nil,
                       partner_verification_document_before: nil,
                       community_review_reason_before: nil,
                       operator_message_body_before: nil,
                       account_notification_before: nil,
                       login_token_before: nil,
                       channel_connection_before: nil,
                       channel_connection_challenge_before: nil,
                       messaging_attempt_before: nil,
                       messaging_suppression_before: nil,
                       record_run: false,
                       run_source: "service")
          @organization = organization
          @dry_run = dry_run
          @report_contact_before = normalize_time(report_contact_before)
          @report_review_before = normalize_time(report_review_before)
          @report_photo_before = normalize_time(report_photo_before)
          @report_coordinates_before = normalize_time(report_coordinates_before)
          @report_coordinate_precision = report_coordinate_precision.presence
          @citizen_phone_before = normalize_time(citizen_phone_before)
          @viber_linkage_before = normalize_time(viber_linkage_before)
          @viber_business_contact_before = normalize_time(viber_business_contact_before)
          @volunteer_availability_before = normalize_time(volunteer_availability_before)
          @komsiluk_post_body_before = normalize_time(komsiluk_post_body_before)
          @komsiluk_delivery_before = normalize_time(komsiluk_delivery_before)
          @chat_feedback_before = normalize_time(chat_feedback_before)
          @partner_private_contact_before = normalize_time(partner_private_contact_before)
          @partner_verification_document_before = normalize_time(partner_verification_document_before)
          @community_review_reason_before = normalize_time(community_review_reason_before)
          @operator_message_body_before = normalize_time(operator_message_body_before)
          @channel_connection_before = normalize_time(channel_connection_before)
          @channel_connection_challenge_before = normalize_time(channel_connection_challenge_before)
          @account_notification_before = normalize_time(account_notification_before)
          @login_token_before = normalize_time(login_token_before)
          @messaging_attempt_before = normalize_time(messaging_attempt_before)
          @messaging_suppression_before = normalize_time(messaging_suppression_before)
          @record_run = record_run
          @run_source = run_source
        end
        # rubocop:enable Metrics/ParameterLists

        def call
          raise ArgumentError, "organization required" unless organization

          run = start_run
          counts = {}
          record_bucket_count(counts, run, :report_evidence_shares) { ReportEvidenceRetention.new(organization:, cutoff: report_review_before, dry_run:).call }
          record_bucket_count(counts, run, :report_contacts) { sweep_report_contacts }
          [:report_dispatch_contents, :report_review_proposals, :report_review_drafts].each do |bucket|
            record_bucket_count(counts, run, bucket) do
              ReportReviewRetention.new(organization:, cutoff: report_review_before, dry_run:).call(bucket:)
            end
          end
          record_bucket_count(counts, run, :report_mail_linked) { ReportMailRetention.new(organization:, cutoff: report_review_before, dry_run:).call }
          record_bucket_count(counts, run, :report_mail_unlinked) { ReportMailRetention.new(organization:, cutoff: report_review_before, dry_run:).call(unlinked: true) }
          record_bucket_count(counts, run, :report_photos) { sweep_report_photos }
          record_bucket_count(counts, run, :report_coordinates) { sweep_report_coordinates }
          record_bucket_count(counts, run, :citizen_phones) { sweep_citizen_phones }
          record_bucket_count(counts, run, :viber_linkages) { sweep_viber_linkages }
          record_bucket_count(counts, run, :viber_business_contacts) { sweep_viber_business_contacts }
          record_bucket_count(counts, run, :volunteer_availabilities) { sweep_volunteer_availabilities }
          record_bucket_count(counts, run, :komsiluk_post_bodies) { sweep_komsiluk_posts }
          record_bucket_count(counts, run, :komsiluk_delivery_data) { sweep_komsiluk_delivery_data }
          record_bucket_count(counts, run, :chat_feedback) { sweep_chat_feedback }
          record_bucket_count(counts, run, :partner_private_contacts) { sweep_partner_private_contacts }
          record_bucket_count(counts, run, :partner_verification_documents) { sweep_partner_verification_documents }
          record_bucket_count(counts, run, :community_review_reasons) { sweep_community_review_reasons }
          record_bucket_count(counts, run, :operator_message_bodies) { sweep_operator_message_bodies }
          record_bucket_count(counts, run, :account_notifications) { sweep_account_notifications }
          record_bucket_count(counts, run, :login_tokens) { sweep_login_tokens }
          record_bucket_count(counts, run, :channel_connections) { sweep_channel_connections }
          record_bucket_count(counts, run, :channel_connection_challenges) { sweep_channel_connection_challenges }
          record_bucket_count(counts, run, :messaging_attempts) { sweep_messaging_attempts }
          record_bucket_count(counts, run, :messaging_suppressions) { sweep_messaging_suppressions }
          run&.finish!(counts: counts)

          Result.new(dry_run: dry_run, counts: counts, run: run)
        rescue StandardError => e
          run&.fail!(e)
          raise
        end

        private

        attr_reader :organization, :dry_run, :report_contact_before, :report_review_before, :report_photo_before,
                    :report_coordinates_before, :report_coordinate_precision,
                    :citizen_phone_before,
                    :viber_linkage_before, :viber_business_contact_before, :volunteer_availability_before,
                    :komsiluk_post_body_before, :komsiluk_delivery_before, :chat_feedback_before,
                    :partner_private_contact_before, :partner_verification_document_before,
                    :community_review_reason_before,
                    :operator_message_body_before, :account_notification_before, :login_token_before, :record_run, :run_source,
                    :channel_connection_before, :channel_connection_challenge_before,
                    :messaging_attempt_before, :messaging_suppression_before

        def start_run
          return unless record_run

          Decidim::Bih::Privacy::RetentionRun.create!(
            organization: organization,
            dry_run: dry_run,
            source: run_source.presence || "service",
            status: "running",
            started_at: Time.current,
            cutoffs: run_cutoffs
          )
        end

        def run_cutoffs
          {
            report_contact_before: retention_cutoff_value(report_contact_before),
            report_review_before: retention_cutoff_value(report_review_before),
            report_photo_before: retention_cutoff_value(report_photo_before),
            report_coordinates_before: retention_cutoff_value(report_coordinates_before),
            report_coordinate_precision: report_coordinate_precision&.to_i,
            citizen_phone_before: retention_cutoff_value(citizen_phone_before),
            viber_linkage_before: retention_cutoff_value(viber_linkage_before),
            viber_business_contact_before: retention_cutoff_value(viber_business_contact_before),
            volunteer_availability_before: retention_cutoff_value(volunteer_availability_before),
            komsiluk_post_body_before: retention_cutoff_value(komsiluk_post_body_before),
            komsiluk_delivery_before: retention_cutoff_value(komsiluk_delivery_before),
            chat_feedback_before: retention_cutoff_value(chat_feedback_before),
            partner_private_contact_before: retention_cutoff_value(partner_private_contact_before),
            partner_verification_document_before: retention_cutoff_value(partner_verification_document_before),
            community_review_reason_before: retention_cutoff_value(community_review_reason_before),
            operator_message_body_before: retention_cutoff_value(operator_message_body_before),
            channel_connection_before: retention_cutoff_value(channel_connection_before),
            channel_connection_challenge_before: retention_cutoff_value(channel_connection_challenge_before),
            account_notification_before: retention_cutoff_value(account_notification_before),
            login_token_before: retention_cutoff_value(login_token_before),
            messaging_attempt_before: retention_cutoff_value(messaging_attempt_before),
            messaging_suppression_before: retention_cutoff_value(messaging_suppression_before)
          }.compact
        end

        def record_bucket_count(counts, run, key)
          count = yield
          counts[key] = count
          run&.update!(counts: counts.transform_keys(&:to_s), total: counts.values.sum)
          count
        end

        def retention_cutoff_value(value)
          value&.utc&.iso8601
        end

        def sweep_report_contacts
          return 0 unless report_contact_before

          scope = reports_before(report_contact_before)
                  .where("reporter_email IS NOT NULL OR reporter_phone IS NOT NULL")
          count = scope.count
          return count if dry_run || count.zero?

          scope.update_all(reporter_email: nil, reporter_phone: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          count
        end

        def sweep_report_photos
          return 0 unless report_photo_before

          scope = reports_before(report_photo_before).joins(:photo_attachment)
          count = scope.count
          return count if dry_run || count.zero?

          scope.find_each { |report| report.photo.purge }
          count
        end

        def sweep_report_coordinates
          return 0 unless report_coordinates_before

          scope = reports_before(report_coordinates_before)
                  .where("latitude IS NOT NULL OR longitude IS NOT NULL")

          if report_coordinate_precision.nil?
            count = scope.count
            return count if dry_run || count.zero?

            scope.update_all(latitude: nil, longitude: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
            return count
          end

          reports = reports_requiring_coordinate_rounding(scope, report_coordinate_precision.to_i)
          count = reports.size
          return count if dry_run || count.zero?

          reports.each do |report|
            precision = report_coordinate_precision.to_i
            report.update_columns( # rubocop:disable Rails/SkipsModelValidations
              latitude: rounded_coordinate(report.latitude, precision),
              longitude: rounded_coordinate(report.longitude, precision),
              updated_at: Time.current
            )
          end
          count
        end

        def reports_requiring_coordinate_rounding(scope, precision)
          scope.filter do |report|
            rounded_coordinate(report.latitude, precision) != report.latitude ||
              rounded_coordinate(report.longitude, precision) != report.longitude
          end
        end

        # Destroys stored citizen phone numbers (the SMS channel, decision
        # 2026-08-31) past the retention window. One row per citizen; the
        # verified_at timestamp is the operational anchor, matching how the
        # number was written (Decidim::Bih::CitizenPhone.store!).
        #
        # Kept as its own bucket alongside sweep_viber_business_contacts even
        # though both tables hold the same proven number — see the note in
        # GrantsSmsAuthorization. Two buckets means an operator can retain the
        # SMS channel and the Viber delivery address independently, and a
        # deletion must clear both.
        # The attempt ledger ages out by when the leg was RECORDED. Nothing here
        # is content: an attempt row holds a channel, a status, a reason code, a
        # kind-scoped destination digest and timestamps.
        def sweep_messaging_attempts
          return 0 unless messaging_attempt_before

          intents = Decidim::Bih::Messaging::Intent.where(organization:).select(:id)
          scope = Decidim::Bih::Messaging::Attempt.where(intent_id: intents)
                                                  .where(created_at: ...messaging_attempt_before)
          count = scope.count
          scope.delete_all unless dry_run || count.zero?
          count
        end

        # An ACTIVE suppression is never deleted, at any age. Deleting one would
        # silently re-enable sending to a destination that refused it, and
        # retention is not a channel for changing policy. Only a suppression
        # that has already been RESOLVED — reactivated, with its evidence
        # recorded — ages out, and it ages out by when it was resolved.
        def sweep_messaging_suppressions
          return 0 unless messaging_suppression_before

          scope = Decidim::Bih::Messaging::Suppression.where(organization:)
                                                      .where.not(reactivated_at: nil)
                                                      .where(reactivated_at: ...messaging_suppression_before)
          count = scope.count
          scope.delete_all unless dry_run || count.zero?
          count
        end

        def sweep_account_notifications
          return 0 unless account_notification_before

          scope = Decidim::Bih::AccountNotification.where(organization:).where(created_at: ...account_notification_before)
          count = scope.count
          scope.delete_all unless dry_run || count.zero?
          count
        end

        def sweep_citizen_phones
          return 0 unless citizen_phone_before

          scope = Decidim::Bih::CitizenPhoneRecord
                  .where(organization:)
                  .where(verified_at: ...citizen_phone_before)
          count = scope.count
          return count if dry_run || count.zero?

          scope.delete_all
          count
        end

        # Viber Business Messages delivery addresses. Mirrors sweep_viber_linkages:
        # same cutoff semantics, same destroy_rows action, separate bucket so an
        # operator can retain the two independently.
        def sweep_viber_business_contacts
          return 0 unless viber_business_contact_before

          scope = Decidim::Bih::Viber::BusinessContact
                  .where(organization:)
                  .where("COALESCE(verified_at, updated_at, created_at) < ?", viber_business_contact_before)
          count = scope.count
          return count if dry_run || count.zero?

          scope.find_each(&:destroy!)
          count
        end

        def sweep_viber_linkages
          return 0 unless viber_linkage_before

          scope = Decidim::Bih::Viber::Linkage
                  .where(organization:)
                  .where("COALESCE(verified_at, updated_at, created_at) < ?", viber_linkage_before)
          count = scope.count
          return count if dry_run || count.zero?

          scope.find_each(&:destroy!)
          count
        end

        def sweep_volunteer_availabilities
          return 0 unless volunteer_availability_before

          scope = Decidim::Bih::VolunteerAvailability
                  .where(organization:)
                  .where(updated_at: ...volunteer_availability_before)
                  .where(
                    "availability IS NOT NULL OR interests IS NOT NULL OR " \
                    "area_scope <> 'city' OR local_area_id IS NOT NULL OR " \
                    "availability_windows <> '[]'::jsonb OR interest_keys <> '[]'::jsonb OR " \
                    "skill_keys <> '[]'::jsonb OR capability_keys <> '[]'::jsonb OR " \
                    "day_keys <> '[]'::jsonb OR month_keys <> '[]'::jsonb OR time_slot_keys <> '[]'::jsonb"
                  )
          count = scope.count
          return count if dry_run || count.zero?

          scope.update_all( # rubocop:disable Rails/SkipsModelValidations
            availability: nil,
            interests: nil,
            area_scope: "city",
            local_area_id: nil,
            availability_windows: [],
            day_keys: [],
            month_keys: [],
            time_slot_keys: [],
            interest_keys: [],
            skill_keys: [],
            capability_keys: [],
            updated_at: Time.current
          )
          count
        end

        # Nullify the body of closed/expired Komšiluk posts past the retention
        # window. The body may carry incidental PII (addresses, names, details).
        # Status (closed/expired/hidden) is preserved so moderation history is
        # retained; only the free-text body is cleared.
        def sweep_komsiluk_delivery_data
          return 0 unless komsiluk_delivery_before

          Komsiluk::NoticePublishing.purge_expired_private_data!(organization:, before: komsiluk_delivery_before, dry_run:)
        end

        def sweep_komsiluk_posts
          return 0 unless komsiluk_post_body_before

          scope = Decidim::Bih::KomsilukPost
                  .where(decidim_organization_id: organization.id, status: %w(closed expired))
                  .where(updated_at: ...komsiluk_post_body_before).where.not(body: nil)
          return scope.count if dry_run

          count = 0
          scope.find_each do |post|
            post.with_lock do
              next unless %w(closed expired).include?(post.status) && post.updated_at < komsiluk_post_body_before && post.body.present?

              post.purge_private_history!
              post.update_columns(body: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
              count += 1
            end
          end
          count
        end

        # Delete old answer-feedback rows. Clicked feedback can include the rated
        # prompt/reply plus a session digest, so the long-term signal should be
        # aggregate counts rather than indefinite rows.
        def sweep_chat_feedback
          return 0 unless chat_feedback_before

          scope = Decidim::Bih::ConciergeFeedback
                  .where(organization:)
                  .where(updated_at: ...chat_feedback_before)
          count = scope.count
          return count if dry_run || count.zero?

          scope.find_each(&:destroy!)
          count
        end

        def sweep_partner_private_contacts
          return 0 unless partner_private_contact_before

          scope = partner_profiles_before(partner_private_contact_before)
                  .where(
                    "private_contact_name IS NOT NULL OR " \
                    "private_contact_email IS NOT NULL OR " \
                    "private_contact_phone IS NOT NULL"
                  )
          count = scope.count
          return count if dry_run || count.zero?

          scope.update_all( # rubocop:disable Rails/SkipsModelValidations
            private_contact_name: nil,
            private_contact_email: nil,
            private_contact_phone: nil,
            updated_at: Time.current
          )
          count
        end

        def sweep_partner_verification_documents
          return 0 unless partner_verification_document_before
          return 0 unless Decidim::Bih::PartnerProfile.reflect_on_association(:verification_documents_attachments)

          scope = partner_profiles_before(partner_verification_document_before)
                  .joins(:verification_documents_attachments)
                  .distinct
          count = scope.count
          return count if dry_run || count.zero?

          scope.find_each { |profile| profile.verification_documents.purge }
          count
        end

        # Private moderation reasons are operationally useful while a partner
        # can correct or review a decision, but they are not permanent public
        # transparency records. Preserve workflow states and timestamps while
        # clearing the free-text reasons after the approved policy window.
        def sweep_community_review_reasons
          return 0 unless community_review_reason_before

          submissions = Decidim::Bih::PartnerProjectSubmission
                        .where(organization:, review_status: %w(rejected changes_requested))
                        .where(reviewed_at: ...community_review_reason_before)
                        .where.not(rejection_reason: nil)
          needs = Decidim::Bih::ContributionNeed
                  .where(organization:, review_status: "rejected")
                  .where(reviewed_at: ...community_review_reason_before)
                  .where.not(rejection_reason: nil)
          offers = Decidim::Bih::ContributionOffer
                   .where(organization:, status: "declined")
                   .where(declined_at: ...community_review_reason_before)
                   .where.not(decline_reason: nil)
          count = submissions.count + needs.count + offers.count
          return count if dry_run || count.zero?

          [submissions, needs].each do |scope|
            scope.update_all(rejection_reason: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          end
          offers.update_all(decline_reason: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          count
        end

        def sweep_operator_message_bodies
          return 0 unless operator_message_body_before

          scope = Decidim::Bih::OperatorMessage
                  .where(organization:)
                  .where(sent_at: ...operator_message_body_before)
                  .where.not(body: OPERATOR_MESSAGE_BODY_REDACTION)
          count = scope.count
          return count if dry_run || count.zero?

          scope.update_all(body: OPERATOR_MESSAGE_BODY_REDACTION, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          count
        end

        def sweep_channel_connections
          return 0 unless channel_connection_before

          scope = Decidim::Bih::ChannelConnection.where(decidim_organization_id: organization.id)
                                                 .where(revoked_at: ...channel_connection_before).where.not(revoked_at: nil)
          count = scope.count
          scope.delete_all unless dry_run || count.zero?
          count
        end

        def sweep_channel_connection_challenges
          return 0 unless channel_connection_challenge_before

          scope = Decidim::Bih::ChannelConnectionChallenge.where(decidim_organization_id: organization.id)
                                                          .where(expires_at: ...[channel_connection_challenge_before, Time.current].min)
          count = scope.count
          scope.delete_all unless dry_run || count.zero?
          count
        end

        def sweep_login_tokens
          return 0 unless login_token_before

          scope = Decidim::Bih::LoginToken
                  .where(organization:)
                  .where("COALESCE(consumed_at, expires_at) < ?", login_token_before)
          count = scope.count
          return count if dry_run || count.zero?

          scope.delete_all
          count
        end

        def reports_before(cutoff)
          Decidim::Bih::Report
            .where(organization:)
            .where("#{Decidim::Bih::Report.table_name}.created_at < ?", cutoff)
        end

        def partner_profiles_before(cutoff)
          Decidim::Bih::PartnerProfile
            .where(organization:)
            .where("#{Decidim::Bih::PartnerProfile.table_name}.created_at < ?", cutoff)
        end

        def rounded_coordinate(value, precision)
          return nil if value.nil?

          value.to_d.round(precision).to_f
        end

        def normalize_time(value)
          case value
          when nil, "" then nil
          when Time then value
          when DateTime, Date then value.to_time
          else Time.zone.parse(value.to_s)
          end
        end
      end
    end
  end
end
