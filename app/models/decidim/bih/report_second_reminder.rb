# frozen_string_literal: true

module Decidim
  module Bih
    # One owner-authorized second question per report. The notification owns the
    # provider evidence; this record owns the question and deadline decision.
    class ReportSecondReminder < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_second_reminders"

      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :question, class_name: "Decidim::Bih::ReportMessage"
      belongs_to :account_notification, class_name: "Decidim::Bih::AccountNotification"
      validates :outcome, inclusion: { in: %w(pending claimed accepted delivered failed skipped replied closed) }
      validate :same_report_and_author

      private

      def same_report_and_author
        errors.add(:question, :invalid) if question && report && question.report_id != report.id
        errors.add(:account_notification, :invalid) if account_notification && report &&
          (account_notification.decidim_organization_id != report.decidim_organization_id ||
           account_notification.decidim_user_id != report.decidim_user_id)
      end
    end
  end
end
