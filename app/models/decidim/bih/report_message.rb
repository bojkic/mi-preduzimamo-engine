# frozen_string_literal: true

module Decidim
  module Bih
    class ReportMessage < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_report_messages"
      include PrivateReportAttachments
      belongs_to :report, class_name: "Decidim::Bih::Report"
      belongs_to :account_notification, class_name: "Decidim::Bih::AccountNotification", optional: true
      belongs_to :actor, class_name: "Decidim::User", optional: true
      has_one_attached :photo, service: ->(_record) { ReportPrivateStorage.service_name }
      has_many_attached :files, service: ->(_record) { ReportPrivateStorage.service_name }
      belongs_to :answers_message, class_name: "Decidim::Bih::ReportMessage", optional: true
      validate do
        if answers_message && (answers_message.report != report || answers_message.kind != "question" || answers_message.actor_role != "staff")
          errors.add(:answers_message,
                     :invalid)
        end
      end
      validates :body, presence: true, length: { maximum: 3000 }
      validates :actor_role, inclusion: { in: %w(staff citizen) }
      validates :kind, inclusion: { in: %w(question reply update resolution feedback) }
      validate :actor_in_organization
      scope :chronological, -> { order(:created_at, :id) }

      # A message body is part of its report's admin search index — the detail
      # that names the place is often in the citizen's reply rather than in the
      # description. after_commit, not after_save: the refresh reads the
      # report's messages back, so it has to see the committed state, and a
      # rolled-back message must not leave its words in the index.
      after_commit :reconsider_evidence, on: [:create, :update]

      after_commit :refresh_report_search_text, on: [:create, :update, :destroy]

      def external_notification_text
        url = URI.join("https://#{report.organization.host}", report.tokenized_status_path).to_s
        "#{report.reference}\n\n#{body}\n\n#{I18n.t("decidim.bih.report_case.reply_link")}: #{url}"
      end

      private

      def reconsider_evidence
        ReportEvidenceAssessmentJob.perform_later(report_id) if actor_role == "citizen" && (photo.attached? || (respond_to?(:files) && files.attached?))
      end

      def refresh_report_search_text
        report&.reload&.refresh_search_text!
      end

      def actor_in_organization
        return unless actor && report && actor.organization != report.organization

        errors.add(:actor, :invalid)
      end
    end
  end
end
