# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxAssociatorTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @previous = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
        end
        teardown { Decidim::Bih.report_reply_mailbox = @previous }
        test "a grouped historical response links three reports in the organisation only" do
          refs = %w(BR-2026-0034 BR-2026-0035 BR-2026-0072)
          refs.each { |reference| Report.create!(organization: @organization, reference:, description: "Fixture report", status: "primljeno") }
          other = create_organization
          Report.create!(organization: other, reference: refs.first, description: "Other tenant", status: "primljeno")
          mail = Mail.read_from_string(File.read(File.join(__dir__, "fixtures/report_mailbox/grouped_history.eml")))
          links = ReportMailbox::Associator.call(mail, organization: @organization)
          assert_equal refs.sort, links.map { |link| link[:report].reference }.sort
          assert links.all? { |link| link[:matching_method] == "reference" && link[:report].organization == @organization }
          assert_equal %w(02-372-1234/26 02-372-1235/26), ReportMailbox::FileNumbers.scan(ReportMailbox::ReplyText.new_part(mail))
        end
        test "capability association is separate from sender trust" do
          report = Report.create!(organization: @organization, description: "Rupa", status: "primljeno")
          ReportMailbox::ReplyAddress.ensure!(report:, audience: "service", correspondents: ["city@city.example"])
          address = ReportMailbox::ReplyAddress.address_for(report:, audience: "service", correspondents: ["city@city.example"])
          mail = Mail.new { from "forged@evil.example"; to address; body "Reply" }
          link = ReportMailbox::Associator.call(mail, organization: @organization).first
          assert_equal "capability", link[:matching_method]
          assert_equal "association", ReportMailbox::Assurance.call(mail, link:, organization: @organization)
        end
        test "reply text excludes quoted content" do
          mail = Mail.new { body "New evidence\nOn yesterday wrote:\nOld instructions\n" }
          assert_equal "New evidence", ReportMailbox::ReplyText.new_part(mail)
        end
      end
    end
  end
end
