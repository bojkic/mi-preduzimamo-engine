# frozen_string_literal: true

require "test_helper"
require "tempfile"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailTransportTest < ActiveSupport::TestCase
        test "missing Gmail credentials fail closed even when a relay is configured" do
          previous = Decidim::Bih.report_mail_transport
          Decidim::Bih.report_mail_transport = "gmail"
          ReportMailbox::Config.stub(:load, nil) do
            assert_raises(ReportMailbox::Transport::Unavailable) { ReportMailbox::Transport.options! }
          end
        ensure
          Decidim::Bih.report_mail_transport = previous
        end

        test "a different authenticated mailbox cannot impersonate the report mailbox" do
          previous = Decidim::Bih.report_mail_transport
          mailbox = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_mail_transport = "gmail"
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          config = ReportMailbox::Config.new({ "host" => "imap.gmail.com", "port" => 993, "tls" => true, "username" => "other@example.org", "password" => "fixture" })
          ReportMailbox::Config.stub(:load, config) do
            assert_raises(ReportMailbox::Transport::Unavailable) { ReportMailbox::Transport.options! }
          end
        ensure
          Decidim::Bih.report_mail_transport = previous
          Decidim::Bih.report_reply_mailbox = mailbox
        end

        test "world-readable credential files are rejected without exposing their contents" do
          Tempfile.create("report-mail-config") do |file|
            file.write({ host: "imap.gmail.com", port: 993, tls: true, username: "prijave@example.org", password: "private fixture value" }.to_json)
            file.flush
            File.chmod(0o644, file.path)
            error = assert_raises(ReportMailbox::Config::InsecureFile) { ReportMailbox::Config.load(file.path) }
            refute_includes error.message, "private fixture value"
          end
        end

        test "Gmail selects SMTP explicitly while relay remains explicit" do
          previous = Decidim::Bih.report_mail_transport
          mailbox = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_mail_transport = "gmail"
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          config = ReportMailbox::Config.new({ "host" => "imap.gmail.com", "port" => 993, "tls" => true, "username" => "prijave@example.org", "password" => "fixture" })
          ReportMailbox::Config.stub(:load, config) do
            options = ReportMailbox::Transport.options!
            assert_equal :smtp, options[:delivery_method]
            assert_equal "prijave@example.org", options[:from]
            assert_equal "smtp.gmail.com", options[:delivery_method_options][:address]
          end
          Decidim::Bih.report_mail_transport = "relay"
          assert_equal({}, ReportMailbox::Transport.options!)
        ensure
          Decidim::Bih.report_mail_transport = previous
          Decidim::Bih.report_reply_mailbox = mailbox
        end
      end
    end
  end
end
