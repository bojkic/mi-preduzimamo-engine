# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    class ReportMailHistoryImportTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
        @report = Report.create!(organization: @organization, description: "Road repair")
        @previous_target = ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"]
        @previous_mailbox = Decidim::Bih.report_reply_mailbox
        ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"] = @organization.id.to_s
        Decidim::Bih.report_reply_mailbox = "reports@example.org"
        @config = ReportMailbox::Config.new("host" => "imap.gmail.com", "port" => 993, "tls" => true,
          "username" => "reports@example.org", "password" => "fixture-password")
        sender = "service@example.org"
        ReportServiceSender.create!(organization: @organization, email: sender, label: "Approved service")
        ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: [sender])
        address = ReportMailbox::ReplyAddress.address_for(report: @report, audience: "service", correspondents: [sender])
        @raw = "From: #{sender}\r\nTo: #{address}\r\nSubject: #{@report.reference}\r\nMessage-ID: <history-fixture@example.org>\r\n\r\nMolimo fotografiju"
      end
      teardown do
        ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"] = @previous_target
        Decidim::Bih.report_reply_mailbox = @previous_mailbox
      end

      def obligation_count
        defined?(ReportObligation) && ReportObligation.available? ? ReportObligation.count : 0
      end

      def import
        ReportMailbox::Config.stub(:load, @config) do
          ReportMailbox::Ingest.new(organization: @organization, adapter: nil).import_history!(raw: @raw)
        end
      end

      test "trusted historical upload is flagged before processing and dedupes without business effects" do
        before = @report.attributes.slice("status", "review_state", "forwarded_at", "response_due_at")
        counts = [Decidim::Notification.count, obligation_count, ReportMessage.count, ReportReviewProposal.count]
        first = import
        assert first.history_only
        assert_equal "history", first.state
        assert_equal "manual_import", first.history_reason
        assert_equal "capability", first.links.find_by!(report: @report).assurance
        assert_equal first.id, import.id
        assert_equal counts, [Decidim::Notification.count, obligation_count, ReportMessage.count, ReportReviewProposal.count]
        assert_equal before, @report.reload.attributes.slice(*before.keys)
        assert_empty InboundEmailEffect.where(inbound_email: first).where.not(effect: "history_linked")
      end

      test "later exact Gmail copy remains history even after activation" do
        import
        cursor = MailboxCursor.create!(organization: @organization, account: "reports@example.org", folder: "All")
        cursor.activate!
        fake = ReportMailbox::FakeAdapter.new(messages: [{ uid: 1, gm_msgid: "gmail-copy", labels: [],
          internal_date: Time.current, size: @raw.bytesize, body: @raw }])
        ReportMailbox::Ingest.new(organization: @organization, adapter: fake).call
        copy = InboundEmail.find_by!(organization: @organization, gm_msgid: "gmail-copy")
        assert copy.history_only
        assert_equal "known_history_content", copy.history_reason
        before = Decidim::Notification.count
        ReportMailbox::ProcessMessage.new(copy).call
        assert_equal before, Decidim::Notification.count
        assert_empty InboundEmailEffect.where(inbound_email: copy).where.not(effect: "history_linked")
      end

      test "operator cannot call previously effectful mail zero-effect history" do
        record = InboundEmail.create!(organization: @organization, account: "reports@example.org", folder: "All", uidvalidity: 1,
          uid: 1, gm_msgid: "live", internal_date: Time.current, size_bytes: @raw.bytesize, raw: @raw)
        ReportMailbox::ProcessMessage.new(record).call
        assert InboundEmailEffect.where(inbound_email: record, effect: "service_response").exists?
        assert_raises(ReportMailbox::HistoryImport::AlreadyEffectful) { ReportMailbox::HistoryImport.mark!(record) }
        refute record.reload.history_only
      end

      test "unmatched unprocessed mail may be marked before worker admission" do
        record = InboundEmail.create!(organization: @organization, account: "reports@example.org", folder: "All", uidvalidity: 1,
          uid: 1, gm_msgid: "stored", internal_date: Time.current, size_bytes: @raw.bytesize, raw: @raw)
        ReportMailbox::HistoryImport.mark!(record)
        assert record.reload.history_only
        assert_equal false, ReportMailbox::ProcessMessage.new(record).call
        assert_empty InboundEmailEffect.where(inbound_email: record)
      end
    end
  end
end
