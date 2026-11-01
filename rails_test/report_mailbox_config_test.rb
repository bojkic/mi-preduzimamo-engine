# frozen_string_literal: true

require "test_helper"
require "tmpdir"

module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxConfigTest < ActiveSupport::TestCase
        test "private fixture loads and hides its password" do
          Dir.mktmpdir do |dir|
            path = File.join(dir, "mailbox.json")
            File.write(path, { host: "imap.gmail.com", port: 993, tls: true, username: "prijave@example.org", password: "fixture-secret" }.to_json)
            File.chmod(0o640, path)
            config = ReportMailbox::Config.load(path)
            assert_equal "smtp.gmail.com", config.smtp_settings[:address]
            assert_equal "prijave@example.org", config.smtp_settings[:user_name]
            refute_includes config.inspect, "fixture-secret"
            File.chmod(0o644, path)
            assert_raises(ReportMailbox::Config::InsecureFile) { ReportMailbox::Config.load(path) }
          end
        end
        test "missing and malformed configuration fail closed for Gmail" do
          previous = Decidim::Bih.report_mail_transport
          Decidim::Bih.report_mail_transport = "gmail"
          ReportMailbox::Config.stub(:load, nil) { assert_raises(ReportMailbox::Transport::Unavailable) { ReportMailbox::Transport.settings! } }
        ensure
          Decidim::Bih.report_mail_transport = previous
        end
      end
    end
  end
end
