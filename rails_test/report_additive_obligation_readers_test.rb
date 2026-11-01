# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportAdditiveObligationReadersTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: "Additive reader fixture", status: "primljeno")
          @email = InboundEmail.create!(organization: @organization, account: "fixture", folder: "All", uidvalidity: 1,
            uid: 1, gm_msgid: SecureRandom.uuid, size_bytes: 1, internal_date: Time.current)
        end

        test "stored mail triage leaves the independent derived intake review visible" do
          task = ReportObligations.open!(@report, kind: "mail_review", source: @email, effect_key: "mail-fixture")
          before = @report.attributes
          tasks = ReportObligations.for_report(@report)
          assert_includes tasks, task
          assert tasks.any? { |item| item.kind == "review" && item.source.nil? && item.new_record? }
          assert_equal before, @report.reload.attributes
        end

        test "stored service review preserves both citizen question and city duty" do
          question = ReportMessage.create!(report: @report, actor_role: "staff", kind: "question", body: "Exact location?")
          @report.update!(review_state: "needs_information", forwarded_at: 1.day.ago, response_due_at: 2.days.from_now)
          ReportObligations.open!(@report, kind: "review", source: @email, effect_key: "service-mail-fixture")
          before = @report.attributes
          tasks = ReportObligations.for_report(@report)
          assert tasks.any? { |item| item.kind == "review" && item.source == @email }
          assert tasks.any? { |item| item.kind == "info_request" && item.source == question }
          assert tasks.any? { |item| item.kind == "city_response" && item.actor == "city" }
          assert_equal before, @report.reload.attributes
        end

        test "matching stored identities do not duplicate or resurrect a completed duty" do
          derived = ReportObligations.derive(@report).find { |task| task.kind == "review" }
          task = ReportObligations.open!(@report, kind: derived.kind, actor: derived.actor, source: derived.source)
          assert_equal [task], ReportObligations.for_report(@report)
          ReportObligations.fulfil!(task, by: @email)
          assert_empty ReportObligations.for_report(@report)
        end
      end
    end
  end
end
