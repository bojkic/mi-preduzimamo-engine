# frozen_string_literal: true
require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportR3ShadowBoundariesTest < ActiveSupport::TestCase
        test "on configuration cannot activate the R3 case agent" do
          organization = create_organization
          Setting.put(organization, "report_review", "case_agent", "on")
          assert_equal "shadow", ReportReviewAssistant.case_agent_mode(organization)
          Setting.put(organization, "report_review", "case_agent", "unknown")
          assert_equal "off", ReportReviewAssistant.case_agent_mode(organization)
        end
        test "off mode preserves legacy eligibility regardless of stored tasks" do
          organization = create_organization
          report = Report.create!(organization:, description: "Road repair", review_state: "validated")
          ReportObligations.open!(report, kind: "review")
          refute ReportReviewAssistant.eligible?(report)
          report.update!(review_state: "pending")
          assert ReportReviewAssistant.eligible?(report)
        end
        test "context derives display obligations without changing legacy fields" do
          organization = create_organization
          report = Report.create!(organization:, description: "Road repair", review_state: "needs_information", forwarded_at: Time.current)
          fields = report.attributes.slice("status", "review_state", "response_due_at", "removed_from_public_at")
          context = nil
          assert_no_difference "ReportObligation.count" do
            context = Ai::ReportReviewContext.new(report)
          end
          assert_equal %w(city_response info_request), context.data[:open_obligations].map { |task| task[:kind] }.sort
          assert_equal fields, report.reload.attributes.slice(*fields.keys)
        end
      end
    end
  end
end
