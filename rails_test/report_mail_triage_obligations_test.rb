# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    class ReportMailTriageObligationsTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @report = Report.create!(organization: @organization, description: "Road repair")
        @email = InboundEmail.create!(organization: @organization, account: "fixture", folder: "All", uidvalidity: 1,
          uid: 1, gm_msgid: SecureRandom.uuid, size_bytes: 1, internal_date: Time.current, state: "review")
      end

      test "mail notices create individual source-linked tasks without changing lifecycle" do
        before = @report.attributes.slice("status", "resolved_at", "review_state", "visibility")
        { "mail_review" => "mail_review", "delivery_exception" => "delivery_exception", "service_response" => "review", "citizen_after_closure" => "dispute_review" }.each do |reason, kind|
          2.times { ReportCityReply::StaffNotice.call(report: @report, inbound_email: @email, reason:) }
          tasks = @report.obligations.where(source: @email, kind:)
          assert_equal 1, tasks.count
          assert_equal "staff", tasks.first.actor
        end
        assert_equal before, @report.reload.attributes.slice(*before.keys)
      end

      test "history and terminal service notices create no business tasks" do
        @email.update!(history_only: true)
        ReportCityReply::StaffNotice.call(report: @report, inbound_email: @email, reason: "mail_review")
        assert_empty @report.obligations.where(source: @email)
        terminal_email = InboundEmail.create!(organization: @organization, account: "fixture", folder: "All", uidvalidity: 1,
          uid: 2, gm_msgid: SecureRandom.uuid, size_bytes: 1, internal_date: Time.current)
        ReportCityReply::StaffNotice.call(report: @report, inbound_email: terminal_email, reason: "terminal_service_reply")
        assert_empty @report.obligations.where(source: terminal_email)
      end

      test "review disposition completes only specified mail producer tasks" do
        other = InboundEmail.create!(organization: @organization, account: "fixture", folder: "All", uidvalidity: 1,
          uid: 2, gm_msgid: SecureRandom.uuid, size_bytes: 1, internal_date: Time.current)
        [@email, other].each do |email|
          %w(mail_review delivery_exception).each { |reason| ReportCityReply::StaffNotice.call(report: @report, inbound_email: email, reason:) }
        end
        ReportCityReply::StaffNotice.fulfil_review!(report: @report, inbound_email: @email, by: @email, kinds: ["mail_review"])
        assert @report.obligations.exists?(source: @email, kind: "mail_review", state: "fulfilled")
        assert @report.obligations.exists?(source: @email, kind: "delivery_exception", state: "open")
        assert @report.obligations.exists?(source: other, kind: "mail_review", state: "open")
      end
    end
  end
end
