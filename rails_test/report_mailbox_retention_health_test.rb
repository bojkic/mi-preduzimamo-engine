# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxRetentionHealthTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @previous = Decidim::Bih.report_mail_transport
          Decidim::Bih.report_mail_transport = "relay"
        end
        teardown { Decidim::Bih.report_mail_transport = @previous }
        def old_mail
          record = InboundEmail.create!(organization: @organization, account: "prijave@example.org", folder: "All", uidvalidity: 1, uid: 1, gm_msgid: "one", internal_date: 2.years.ago, size_bytes: 1, raw: "private", state: "history")
          record.update_columns(updated_at: 2.years.ago)
          record
        end
        test "multi-linked mail survives while any report remains open" do
          record = old_mail
          %w(rijeseno primljeno).each do |status|
            report = Report.create!(organization: @organization, description: "Rupa", status:)
            report.update_columns(updated_at: 2.years.ago)
            record.links.create!(report:, matching_method: "manual", assurance: "association")
          end
          assert_equal 0, Privacy::ReportMailRetention.new(organization: @organization, cutoff: 1.year.ago, dry_run: false).call
          assert_equal "private", record.reload.raw
        end
        test "unlinked bucket redacts expired content only" do
          record = old_mail
          assert_equal 1, Privacy::ReportMailRetention.new(organization: @organization, cutoff: 1.year.ago, dry_run: false).call(unlinked: true)
          assert_nil record.reload.raw
          assert record.data_redacted_at
        end
        test "uncertain report transport is unhealthy until reconciled and stays tenant scoped" do
          MailboxCursor.create!(organization: @organization, account: "prijave@example.org", folder: "All", last_success_at: Time.current)
          other_organization = create_organization
          [other_organization, @organization].each_with_index do |organization, index|
            report = Report.create!(organization:, description: "Transport fixture")
            actor = FactoryBot.create(:user, :admin, :confirmed, organization:)
            dispatch = report.dispatches.create!(approved_by: actor, kind: "initial", state: "unknown", input_digest: "fixture",
              deduplication_key: "unknown-#{index}", message_id: "unknown-#{index}@example.org", snapshot: { to: ["city@example.org"], body: "Fixture" })
            summary = ReportMailbox::Health.summary(organization: @organization)
            if organization == @organization
              assert_equal "red", summary[:status]
              assert_includes summary[:reasons], "unknown_dispatches"
              dispatch.update!(state: "not_sent")
              assert_equal "green", ReportMailbox::Health.summary(organization: @organization)[:status]
            else
              assert_equal "green", summary[:status]
            end
          end
        end

        test "a single rejected LOGIN is immediately red without classifying generic command denial as auth" do
          cursor = MailboxCursor.create!(organization: @organization, account: "fixture@example.org", folder: "All",
            last_success_at: Time.current, consecutive_failures: 1, last_error_class: ReportMailbox::ImapAdapter::AuthenticationFailed.name)
          assert_includes ReportMailbox::Health.summary(organization: @organization)[:reasons], "authentication_failure"
          cursor.update!(last_error_class: "Net::IMAP::NoResponseError")
          refute_includes ReportMailbox::Health.summary(organization: @organization)[:reasons], "authentication_failure"
        end

        test "failed or stale mailbox states are red" do
          cursor = MailboxCursor.create!(organization: @organization, account: "prijave@example.org", folder: "All", last_success_at: 1.hour.ago, consecutive_failures: 3)
          assert_equal %w(consecutive_failures stale_poll), ReportMailbox::Health.summary(organization: @organization)[:reasons]
          cursor.update!(last_success_at: Time.current, consecutive_failures: 0)
          record = old_mail
          record.update!(state: "failed")
          assert_includes ReportMailbox::Health.summary(organization: @organization)[:reasons], "failed_message"
        end
      end
    end
  end
end
