# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportCaseMessageEmailTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @author = FactoryBot.create(:user, :confirmed, organization: @organization)
          @report = Report.create!(organization: @organization, author: @author, description: "Private question email fixture")
          @previous_mailbox = Decidim::Bih.report_reply_mailbox
          @previous_transport = Decidim::Bih.report_mail_transport
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          Decidim::Bih.report_mail_transport = "relay"
        end

        teardown do
          Decidim::Bih.report_reply_mailbox = @previous_mailbox
          Decidim::Bih.report_mail_transport = @previous_transport
        end

        test "question email preserves full external text and private status link" do
          question = @report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which entrance needs repair?")
          mail = ReporterMailer.case_message(question).message
          assert_equal [@author.email], mail.to
          assert_equal question.external_notification_text, mail.body.decoded
          assert_includes mail.body.decoded, @report.tokenized_status_path
          capability = ReportMailbox::ReplyAddress.resolve(mail.reply_to.first, organization: @organization)
          assert_equal "citizen", capability.audience
          assert_equal @report, capability.report
          assert_equal question, capability.question_message
          assert capability.correspondent?(@author.email)
          refute_includes mail.body.decoded, mail.reply_to.first
        end

        test "each question has its own stable capability and a plain update has no question binding" do
          first = @report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which entrance?")
          second = @report.case_messages.create!(actor_role: "staff", kind: "question", body: "Which side?")
          update = @report.case_messages.create!(actor_role: "staff", kind: "update", body: "We recorded the service reply.")
          first_mail = ReporterMailer.case_message(first).message
          assert_equal first_mail.reply_to, ReporterMailer.case_message(first).message.reply_to
          second_mail = ReporterMailer.case_message(second).message
          refute_equal first_mail.reply_to, second_mail.reply_to
          assert_equal second, ReportMailbox::ReplyAddress.resolve(second_mail.reply_to.first, organization: @organization).question_message
          update_mail = ReporterMailer.case_message(update).message
          assert_equal update.external_notification_text, update_mail.body.decoded
          assert_nil ReportMailbox::ReplyAddress.resolve(update_mail.reply_to.first, organization: @organization).question_message
          refute_equal first_mail.reply_to, update_mail.reply_to
        end
      end
    end
  end
end
