# frozen_string_literal: true

module Decidim
  module Bih
    module Privacy
      # Explicit operator-triggered retention sweep. It is intentionally not
      # scheduled by the engine; production policy periods must be approved and
      # passed in by the host/operator. Defaults to dry-run.
      class RetentionSweepJob < Decidim::ApplicationJob
        queue_as :default

        discard_on ActiveJob::DeserializationError

        # rubocop:disable Metrics/ParameterLists
        def perform(organization_id:, dry_run: true,
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
                    channel_connection_before: nil,
                    channel_connection_challenge_before: nil,
                    account_notification_before: nil,
                    login_token_before: nil,
                    messaging_attempt_before: nil,
                    messaging_suppression_before: nil)
          organization = Decidim::Organization.find_by(id: organization_id)
          return unless organization

          attributes = {
            organization: organization,
            report_contact_before: report_contact_before,
            report_review_before: report_review_before,
            report_photo_before: report_photo_before,
            report_coordinates_before: report_coordinates_before,
            report_coordinate_precision: report_coordinate_precision,
            citizen_phone_before: citizen_phone_before,
            viber_linkage_before: viber_linkage_before,
            viber_business_contact_before: viber_business_contact_before,
            volunteer_availability_before: volunteer_availability_before,
            komsiluk_post_body_before: komsiluk_post_body_before,
            komsiluk_delivery_before:,
            chat_feedback_before: chat_feedback_before,
            partner_private_contact_before: partner_private_contact_before,
            partner_verification_document_before: partner_verification_document_before,
            community_review_reason_before: community_review_reason_before,
            operator_message_body_before: operator_message_body_before,
            channel_connection_before: channel_connection_before,
            channel_connection_challenge_before: channel_connection_challenge_before,
            account_notification_before: account_notification_before,
            login_token_before: login_token_before,
            messaging_attempt_before: messaging_attempt_before,
            messaging_suppression_before: messaging_suppression_before,
            record_run: true,
            run_source: "job"
          }
          if dry_run
            Decidim::Bih::Privacy::RetentionSweep.call(**attributes, dry_run: true)
          else
            Decidim::Bih::Privacy::RetentionSweep.authorized_live_call(**attributes)
          end
        end
        # rubocop:enable Metrics/ParameterLists
      end
    end
  end
end
