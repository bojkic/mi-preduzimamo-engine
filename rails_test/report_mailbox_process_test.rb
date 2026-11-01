# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxProcessTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: "Rupa na putu", status: "primljeno")
        end
        def email(history: false, headers: "")
          raw = "From: city@city.example\r\nTo: prijave@example.org\r\nSubject: #{@report.reference}\r\n#{headers}\r\nOdgovor"
          InboundEmail.create!(organization: @organization, account: "prijave@example.org", folder: "All", uidvalidity: 1, uid: 1, gm_msgid: "one", internal_date: Time.current, size_bytes: raw.bytesize, raw:, body_text: "Odgovor", subject: @report.reference, history_only: history, history_reason: history ? "pre_activation" : nil)
        end
        test "historical bounce writes no bounce event or notification and processing is idempotent" do
          record = email(history: true, headers: "Auto-Submitted: auto-replied\r\n")
          before = @report.attributes.slice("status", "review_state", "forwarded_at", "response_due_at")
          assert_no_difference("Decidim::Notification.count") { ReportMailbox::ProcessMessage.new(record).call }
          assert_equal "history", record.reload.state
          assert_equal before, @report.reload.attributes.slice(*before.keys)
          assert_equal 1, record.links.count
          assert_equal false, ReportMailbox::ProcessMessage.new(record).call
        end
        test "forged subject association goes to staff review without changing status" do
          record = email
          ReportMailbox::ProcessMessage.new(record).call
          assert_equal "review", record.reload.state
          assert_equal "association", record.links.first.assurance
          assert_equal "primljeno", @report.reload.status
        end
        test "recovery releases an abandoned claim and fails exhausted work" do
          record = email
          record.update!(state: "processing", locked_at: 11.minutes.ago, processing_attempts: 5)
          record.update_columns(created_at: 20.minutes.ago)
          ReportMailboxRecoveryJob.perform_now(@organization.id)
          assert_equal "failed", record.reload.state
        end
      end
    end
  end
end
