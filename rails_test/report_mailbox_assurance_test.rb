# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxAssuranceTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: "Rupa na putu", status: "primljeno")
          @previous = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          ReportServiceSender.create!(organization: @organization, email: "city@city.example", label: "City")
        end
        teardown { Decidim::Bih.report_reply_mailbox = @previous }
        test "service capability needs its approved sender" do
          cap = ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: ["city@city.example"])
          link = { report: @report, matching_method: "capability", capability: cap }
          mail = Mail.new { from "city@city.example" }
          assert_equal "capability", ReportMailbox::Assurance.call(mail, link:, organization: @organization)
          mail.from = "stranger@city.example"
          assert_equal "association", ReportMailbox::Assurance.call(mail, link:, organization: @organization)
        end
        test "forged association never authenticates sender" do
          mail = Mail.new { from "city@city.example"; in_reply_to "known@example.org" }
          link = { report: @report, matching_method: "in_reply_to", capability: nil }
          assert_equal "association", ReportMailbox::Assurance.call(mail, link:, organization: @organization)
        end
        test "injected authentication stamp is ignored" do
          mail = Mail.read_from_string("From: city@city.example\r\nAuthentication-Results: evil.example; dkim=pass header.d=city.example\r\n\r\nBody")
          assert_equal({}, ReportMailbox::GoogleAuthentication.parse(mail))
        end
        test "lower Google-looking sender stamp cannot override top receiver failure" do
          mail = Mail.read_from_string("From: city@city.example\r\nAuthentication-Results: mx.google.com; dkim=fail header.d=city.example\r\nAuthentication-Results: mx.google.com; dkim=pass header.d=city.example\r\n\r\nBody")
          assert_equal "none", ReportMailbox::GoogleAuthentication.parse(mail)["dkim"]
        end
      end
    end
  end
end
