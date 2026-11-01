# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxIngestTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @previous = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
        end
        teardown { Decidim::Bih.report_reply_mailbox = @previous }
        def adapter(messages)
          ReportMailbox::FakeAdapter.new(messages: messages.map { |item| { gm_thrid: "thread", labels: [], internal_date: Time.current, size: 100 }.merge(item) })
        end
        def raw(body = "Reply") = "From: city@city.example\r\nTo: prijave@example.org\r\nMessage-ID: <same@city.example>\r\nSubject: Reply\r\n\r\n#{body}"
        test "oversized metadata does not fetch body or block following mail" do
          fake = adapter([{ uid: 1, gm_msgid: "large", size: 26.megabytes }, { uid: 2, gm_msgid: "normal", body: raw }])
          result = ReportMailbox::Ingest.new(organization: @organization, adapter: fake).call
          assert_equal 1, result[:oversized]
          assert_equal 1, result[:stored]
          assert_equal [2], fake.body_requests
          assert_equal 2, MailboxCursor.find_by!(organization: @organization).last_uid
        end
        test "provider replay dedupes and reused Message-ID content is flagged" do
          first = [{ uid: 1, gm_msgid: "one", body: raw("First") }]
          ReportMailbox::Ingest.new(organization: @organization, adapter: adapter(first)).call
          assert_equal 0, ReportMailbox::Ingest.new(organization: @organization, adapter: adapter(first)).call[:stored]
          ReportMailbox::Ingest.new(organization: @organization, adapter: adapter([{ uid: 2, gm_msgid: "two", body: raw("Changed") }])).call
          assert InboundEmail.find_by!(gm_msgid: "two").message_id_conflict
          assert_equal 2, InboundEmail.count
        end
        test "activation watermark cannot move" do
          cursor = MailboxCursor.create!(organization: @organization, account: "prijave@example.org", folder: "All")
          cursor.activate!
          assert_raises(ArgumentError) { cursor.activate! }
        end
      end
    end
  end
end
