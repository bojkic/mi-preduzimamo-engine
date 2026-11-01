# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportCitizenEmailReplyTest < ActiveSupport::TestCase
        test "staff question email reaches its author with an exact-question citizen capability" do
          organization = create_organization
          author = FactoryBot.create(:user, :confirmed, organization:)
          report = Report.create!(organization:, author:, description: "Question mail fixture", status: "primljeno")
          previous_mailbox = Decidim::Bih.report_reply_mailbox
          previous_transport = Decidim::Bih.report_mail_transport
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          Decidim::Bih.report_mail_transport = "relay"
          question = report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which entrance?")
          notification = AccountNotification.create!(organization:, user: author, topic: "report_updates", status: "pending",
            payload: { text: question.external_notification_text }, deduplication_digest: "question-fixture", expires_at: 1.hour.from_now)
          question.update!(account_notification: notification)
          Messaging::ProactiveEmail.stub(:allowed?, true) do
            AccountNotifications.send(:deliver_email, notification)
          end
          mail = ActionMailer::Base.deliveries.last
          assert_equal [author.email], mail.to
          assert_includes mail.body.decoded, report.tokenized_status_path
          capability = ReportMailbox::ReplyAddress.resolve(mail.reply_to.first, organization:)
          assert_equal "citizen", capability.audience
          assert_equal question, capability.question_message
          other_question = report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which side?")
          other_mail = ReporterMailer.case_message(other_question).message
          refute_equal mail.reply_to, other_mail.reply_to
          assert_equal other_question, ReportMailbox::ReplyAddress.resolve(other_mail.reply_to.first, organization:).question_message
        ensure
          Decidim::Bih.report_reply_mailbox = previous_mailbox
          Decidim::Bih.report_mail_transport = previous_transport
        end

        test "multi-file validator rejects unsupported and oversized uploads" do
          assert_raises(ReportCaseWorkflow::Invalid) do
            ReportMailbox::CitizenReply.validated_files([{ io: StringIO.new("executable"), content_type: "application/octet-stream", filename: "evil.exe" }])
          end
        end
        test "question answer belongs to the same report" do
          organization = create_organization
          first = Report.create!(organization:, description: "Rupa", status: "primljeno")
          second = Report.create!(organization:, description: "Lampa", status: "primljeno")
          question = first.case_messages.create!(actor_role: "staff", kind: "question", body: "Gdje?")
          reply = second.case_messages.new(actor_role: "citizen", kind: "reply", body: "Ovdje", answers_message: question)
          refute reply.valid?
          assert reply.errors[:answers_message].any?
        end
      end
    end
  end
end
