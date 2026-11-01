# frozen_string_literal: true

module Decidim
  module Bih
    # Retired 2026-10-06 (owner review of the bell list): a failed AI draft
    # needs no staff action — the case card already says no suggestion is
    # available and new reports have their own bell — yet the bell read like
    # a case status ("BR-…: Čekamo odgovor službe"). Jobs already queued end here.
    # Compatibility tombstone for serialized jobs from before the single cutover.
    # No producer remains; keep for one release so old retries deserialize safely.
    class ReportReviewFailureAlertJob < ApplicationJob
      queue_as :reports

      def perform(proposal_id)
        Rails.logger.info("[ReportReviewFailureAlertJob] retired proposal=#{proposal_id}")
      end
    end
  end
end
