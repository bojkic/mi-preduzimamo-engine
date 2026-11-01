# frozen_string_literal: true
require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportMailTriageControllerTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization)
          @report = Report.create!(organization: @organization, description: "Mail triage fixture")
          @email = mail_fixture(1)
          @other_email = mail_fixture(2)
          [@email, @other_email].each do |mail|
            InboundEmailLink.create!(inbound_email: mail, report: @report, matching_method: "manual", assurance: "association")
            %w(mail_review delivery_exception).each { |reason| ReportCityReply::StaffNotice.call(report: @report, inbound_email: mail, reason:) }
          end
        end

        def mail_fixture(uid)
          InboundEmail.create!(organization: @organization, account: "fixture", folder: "All", uidvalidity: 1,
            uid:, gm_msgid: SecureRandom.uuid, size_bytes: 1, internal_date: Time.current, state: "review")
        end

        # Exercise the actual controller actions and persisted effects; authentication
        # and mailbox-role permission are covered by the separate admin boundary test.
        def invoke(action)
          controller = Admin::ReportInboundEmailsController.new
          controller.params = ActionController::Parameters.new(id: @email.id, references: @report.reference)
          controller.stub(:scope, InboundEmail.where(organization: @organization)) do
            controller.stub(:current_organization, @organization) do
              controller.stub(:current_user, @admin) do
                controller.stub(:audit_operator_action!, nil) do
                  controller.stub(:report_inbound_email_path, "/fixture") do
                    controller.stub(:report_inbound_emails_path, "/fixtures") do
                      controller.stub(:redirect_to, nil) { controller.public_send(action) }
                    end
                  end
                end
              end
            end
          end
        end

        test "manual link completes original mail review while keeping new service review and other mail tasks" do
          invoke(:link)
          assert @report.obligations.exists?(source: @email, kind: "mail_review", state: "fulfilled")
          assert @report.obligations.exists?(source: @email, kind: "review", state: "open")
          assert @report.obligations.exists?(source: @email, kind: "delivery_exception", state: "open")
          assert @report.obligations.exists?(source: @other_email, kind: "mail_review", state: "open")
          assert_equal "processed", @email.reload.state
        end

        test "dismiss closes selected mail review interpretations but leaves delivery dispute and other mail" do
          uncertain = ReportObligations.open!(@report, kind: "review", source: @email, effect_key: "uncertain-fixture")
          dispute = ReportObligations.open!(@report, kind: "dispute_review", source: @email, effect_key: "dispute-fixture")
          invoke(:dismiss)
          assert_equal "fulfilled", uncertain.reload.state
          assert_equal "open", dispute.reload.state
          assert @report.obligations.exists?(source: @email, kind: "mail_review", state: "fulfilled")
          assert @report.obligations.exists?(source: @email, kind: "delivery_exception", state: "open")
          assert @report.obligations.exists?(source: @other_email, kind: "mail_review", state: "open")
          assert_equal "ignored", @email.reload.state
          assert_equal @admin, @email.dismissed_by
        end
      end
    end
  end
end
