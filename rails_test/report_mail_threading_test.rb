# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportMailThreadingTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @actor = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @report = Report.create!(organization: @organization, description: "Broken lamp", category: "rasvjeta", severity: "normalan", forwarding_recipient: "a@city.example")
          @mailbox = Decidim::Bih.report_reply_mailbox
          @transport = Decidim::Bih.report_mail_transport
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          Decidim::Bih.report_mail_transport = "relay"
          ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: ["a@city.example"])
        end

        teardown do
          Decidim::Bih.report_reply_mailbox = @mailbox
          Decidim::Bih.report_mail_transport = @transport
        end

        def accepted(recipient, message_id, at)
          @report.dispatches.create!(approved_by: @actor, kind: "initial", state: "accepted", accepted_at: at,
            input_digest: "fixture", deduplication_key: message_id, message_id:,
            snapshot: { to: [recipient], from: ["prijave@example.org"], subject: "Fixture", body: "Fixture", attachments: [] })
        end

        def supplement
          ReportCaseWorkflow.stub(:recipients, ["a@city.example", "b@city.example"]) do
            ReportDispatching.preview(report: @report, kind: "supplement", text: "Requested details")
          end
        end

        test "supplement includes only accepted messages from its recipient conversation" do
          accepted("a@city.example", "first-a@city.example", 2.hours.ago)
          accepted("b@city.example", "other-b@city.example", 1.hour.ago)
          accepted("a@city.example", "last-a@city.example", 30.minutes.ago)
          mail = supplement
          assert_equal "last-a@city.example", mail.in_reply_to
          assert_equal ["first-a@city.example", "last-a@city.example"], mail.references
          refute_includes mail.to_s, "other-b@city.example"
          refute_includes mail.body.decoded, @report.status_token
          refute_includes mail.body.decoded, mail.reply_to.first
        end

        test "reply capability changes the approval digest and immutable mail preserves headers" do
          accepted("a@city.example", "first-a@city.example", 1.hour.ago)
          mail = supplement
          digest = ReportDispatching.mail_digest(mail)
          original_reply_to = mail.reply_to
          mail.reply_to = "prijave+s-different@example.org"
          refute_equal digest, ReportDispatching.mail_digest(mail)
          mail.reply_to = original_reply_to
          dispatch = @report.dispatches.create!(approved_by: @actor, kind: "supplement", input_digest: "fixture",
            deduplication_key: "snapshot-fixture", message_id: "snapshot@city.example", snapshot: ReportEvidence.snapshot(mail))
          delivered = ReportDispatchMailer.delivery(dispatch.id).message
          assert_equal original_reply_to, delivered.reply_to
          assert_equal mail.in_reply_to, delivered.in_reply_to
          assert_equal mail.references, delivered.references
          refute_includes delivered.to_s, @report.status_token
        end
      end
    end
  end
end
