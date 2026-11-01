# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    class ReportObligationsTest < ActiveSupport::TestCase
      setup do
        @organization = create_organization
        @report = Report.create!(organization: @organization, description: "Pavement needs repair", category: "putevi")
        @staff = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
      end
      test "citizen and city obligations coexist and fulfilment is identity based" do
        first = @report.case_messages.create!(actor: @staff, actor_role: "staff", kind: "question", body: "Which entrance?")
        second = @report.case_messages.create!(actor: @staff, actor_role: "staff", kind: "question", body: "Since when?")
        a = ReportObligations.open!(@report, kind: :info_request, source: first)
        b = ReportObligations.open!(@report, kind: :info_request, source: second)
        city = ReportObligations.open!(@report, kind: :city_response)
        reply = @report.case_messages.create!(actor_role: "citizen", kind: "reply", body: "North entrance")
        assert_equal :ambiguous, ReportObligations.answered_by(@report, reply)
        ReportObligations.fulfil!(a, by: reply)
        assert_equal "fulfilled", a.reload.state
        assert b.reload.open?
        assert city.reload.open?
        assert_equal b, ReportObligations.answered_by(@report, reply)
      end
      test "derived forwarded citizen question retains both actors without writes" do
        @report.update!(forwarded_at: Time.current, review_state: "needs_information")
        before = @report.obligations.count
        derived = ReportObligations.derive(@report)
        assert_equal %w(city_response info_request), derived.map(&:kind).sort
        assert derived.none?(&:persisted?)
        assert_equal before, @report.obligations.count
      end
      test "derivation covers legacy stages and actors without altering persisted inputs" do
        due = 7.days.from_now
        combinations = [
          ["primljeno", "pending", nil, %w(review)],
          ["primljeno", "validated", nil, %w(review)],
          ["primljeno", "needs_information", nil, %w(info_request)],
          ["proslijedjeno", "validated", 2.days.ago, %w(city_response)],
          ["u_obradi", "needs_information", 2.days.ago, %w(city_response info_request)],
          ["u_obradi", "pending", 2.days.ago, %w(city_response review)],
          ["planirano", "validated", nil, %w(review)],
          ["rijeseno", "validated", 2.days.ago, []],
          ["odbijeno", "rejected", nil, []]
        ]
        combinations.each do |status, review_state, forwarded_at, kinds|
          @report.update_columns(status:, review_state:, forwarded_at:, response_due_at: due) # rubocop:disable Rails/SkipsModelValidations -- exercise legacy values without workflow callbacks
          before = @report.reload.attributes
          obligations = ReportObligations.derive(@report)
          assert_equal kinds, obligations.map(&:kind).sort, [status, review_state].inspect
          assert obligations.none?(&:persisted?)
          assert_equal before, @report.reload.attributes
          assert_equal 0, @report.obligations.count
        end
      end
      test "display-only derivation leaves exact race snapshot output and legacy report facts unchanged" do
        at = Time.current
        before = Race::SnapshotBuilder.new(organization: @organization, at:).call
        facts = @report.reload.attributes
        assert_no_difference ["ReportObligation.count", "ReportEvent.count"] do
          2.times do
            ReportObligations.derive(@report)
            ReportObligations.next_action(@report)
          end
        end
        assert_equal before, Race::SnapshotBuilder.new(organization: @organization, at:).call
        assert_equal facts, @report.reload.attributes
      end
      %w(reject resolve duplicate).each do |decision|
        test "#{decision} ends citizen and City waits but keeps explicit staff tasks" do
          # A forwarded case offers resolve/reject; duplicate is offered before forwarding.
          @report.update!(review_state: "needs_information")
          @report.update!(forwarded_at: 1.day.ago, status: "proslijedjeno") unless decision == "duplicate"
          question = @report.case_messages.create!(actor: @staff, actor_role: "staff", kind: "question", body: "Which entrance?")
          citizen = ReportObligations.open!(@report, kind: :info_request, source: question)
          city = ReportObligations.open!(@report, kind: :city_response)
          approval = ReportObligations.open!(@report, kind: :dispatch_approval)
          target = Report.create!(organization: @organization, description: "Same pavement")
          values = { reason: "Deliberate staff decision", resolution_evidence: "Inspected on site", duplicate_reference: target.reference }

          ReportDecision.new(@report, @staff).call(action: decision, values:, version: ReportReviewVersion.digest(@report), confirmed: true)

          assert_equal %w(superseded superseded), [citizen.reload.state, city.reload.state]
          assert_equal @report, city.fulfilled_by
          assert_equal "case_closed", city.metadata["closed_reason"]
          assert approval.reload.open?
          assert_empty ReportObligations.for_report(@report.reload)
        end
      end

      test "only the closing save ends waits; a later edit or reopen leaves history alone" do
        city = ReportObligations.open!(@report, kind: :city_response)
        @report.update!(status: "odbijeno", review_state: "rejected")
        assert_equal "superseded", city.reload.state
        reopened = ReportObligations.open!(@report, kind: :city_response)
        @report.update!(internal_note: "Checked later")
        assert reopened.reload.open?
        @report.update!(status: "primljeno", review_state: "pending")
        assert reopened.reload.open?
        assert_equal "superseded", city.reload.state
      end

      test "next action uses earliest due and supersession preserves unrelated obligations" do
        early = ReportObligations.open!(@report, kind: :review, due_at: 1.hour.from_now)
        later = ReportObligations.open!(@report, kind: :city_response, due_at: 5.days.from_now)
        assert_equal early, ReportObligations.next_action(@report)
        ReportObligations.supersede!(early, by: @report, replacements: [{ kind: :dispatch_approval }])
        assert_equal "superseded", early.reload.state
        assert later.reload.open?
        assert_equal I18n.t("decidim.bih.report_obligations.city_response", locale: :sr), ReportObligations.label(later, locale: :sr)
      end
    end
  end
end
