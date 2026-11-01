# frozen_string_literal: true

module Decidim
  module Bih
    class ReportMailboxRecoveryJob < ApplicationJob
      queue_as :default
      def perform(organization_id = nil)
        ReportPrivateStorageCleanup.recover_pending!(organization_id:)
        scope = InboundEmail.all
        scope = scope.where(decidim_organization_id: organization_id) if organization_id
        scope.where(state: "processing").where(locked_at: ...10.minutes.ago).update_all(state: "stored", locked_at: nil) # rubocop:disable Rails/SkipsModelValidations -- atomic expiry of stale processing claims
        organizations = organization_id ? Decidim::Organization.where(id: organization_id) : Decidim::Organization.all
        organizations.find_each { |organization| ReportShadowSweep.resume!(organization) }
        ReportReviewProposalRecovery.run!(organization_id:)
        scope.where(state: "stored").where(created_at: ...2.minutes.ago).find_each do |email|
          if email.processing_attempts >= 5
            email.update!(state: "failed", review_reason: "processing_exhausted")
            Rails.logger.error("[report-mailbox] processing exhausted id=#{email.id}")
          else
            ReportMailboxProcessJob.perform_later(email.id)
          end
        end
      end
    end
  end
end
