# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    class ReportMailboxTargetTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @other = create_organization
        @previous_target = ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"]
        @previous_mailbox = Decidim::Bih.report_reply_mailbox
        Decidim::Bih.report_reply_mailbox = "reports@example.org"
        @config = ReportMailbox::Config.new("host" => "imap.gmail.com", "port" => 993, "tls" => true,
          "username" => "REPORTS@example.org", "password" => "fixture-password")
      end
      teardown do
        ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"] = @previous_target
        Decidim::Bih.report_reply_mailbox = @previous_mailbox
      end

      test "shared mailbox never defaults to every tenant" do
        ENV.delete("MI_REPORT_MAILBOX_ORGANIZATION_ID")
        ReportMailbox::Config.stub(:load, @config) do
          assert_raises(ReportMailbox::Config::Invalid) { ReportMailbox::Target.resolve! }
        end
      end

      test "explicit tenant and normalized account are shared by polling and activation" do
        ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"] = @organization.id.to_s
        ReportMailbox::Config.stub(:load, @config) do
          target = ReportMailbox::Target.resolve!
          assert_equal @organization, target.organization
          assert_equal "reports@example.org", target.account
          fake = ReportMailbox::FakeAdapter.new
          cursor = ReportMailbox::ImapAdapter.stub(:new, fake) do
            ReportMailbox::Target.activate!(organization_id: @organization.id)
          end
          assert_equal cursor, MailboxCursor.find_by(organization: @organization, account: Decidim::Bih.report_reply_mailbox.downcase)
          assert cursor.reload.activation_at
          assert_nil MailboxCursor.find_by(organization: @other, account: target.account)
          ReportMailbox::ImapAdapter.stub(:new, ->(*) { flunk "Wrong activation tenant must not open IMAP" }) do
            assert_raises(ReportMailbox::Config::Invalid) { ReportMailbox::Target.activate!(organization_id: @other.id) }
          end
          assert_raises(ReportMailbox::Config::Invalid) { ReportMailboxIngestJob.perform_now(@other.id) }
        end
      end

      test "an explicit target cannot reuse a mailbox already owned by another tenant" do
        ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"] = @organization.id.to_s
        MailboxCursor.create!(organization: @other, account: "reports@example.org", folder: "All")
        ReportMailbox::Config.stub(:load, @config) do
          assert_raises(ReportMailbox::Config::Invalid) { ReportMailbox::Target.resolve! }
        end
      end

      test "mismatched credential identity fails before mailbox access or cursor creation" do
        ENV["MI_REPORT_MAILBOX_ORGANIZATION_ID"] = @organization.id.to_s
        Decidim::Bih.report_reply_mailbox = "other@example.org"
        ReportMailbox::Config.stub(:load, @config) do
          assert_raises(ReportMailbox::Config::Invalid) { ReportMailbox::Target.resolve! }
          assert_empty MailboxCursor.where(organization: @organization)
        end
      end
    end
  end
end
