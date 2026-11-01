# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportReplyAddressTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @report = Report.create!(organization: @organization, description: "Rupa na putu.", status: "primljeno")
          @previous = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          @city = ["intake@city.example"]
        end

        teardown { Decidim::Bih.report_reply_mailbox = @previous }

        def service_address
          ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: @city)
          ReportMailbox::ReplyAddress.address_for(report: @report, audience: "service", correspondents: @city)
        end

        def resolve(address, organization: @organization) = ReportMailbox::ReplyAddress.resolve(address, organization:)

        # Deterministic tampering: always change the first token character to a different one.
        def tamper(address)
          address.sub(/([sc]-)([a-z2-7])/) { "#{Regexp.last_match(1)}#{Regexp.last_match(2) == 'a' ? 'b' : 'a'}" }
        end

        test "service address carries 136 bits and resolves to its capability" do
          address = service_address
          assert_match(/\Aprijave\+s-[a-z2-7]{28}@example\.org\z/, address)
          capability = resolve(address)
          assert_equal [@report.id, "service"], [capability.decidim_bih_report_id, capability.audience]
          assert capability.correspondent?("Intake@City.example")
        end

        test "the same report, audience and correspondents reuse one capability" do
          assert_equal service_address, service_address
        end

        test "audiences are separate capabilities" do
          ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "citizen", correspondents: ["author@example.org"])
          citizen = ReportMailbox::ReplyAddress.address_for(report: @report, audience: "citizen", correspondents: ["author@example.org"])
          refute_equal service_address, citizen
          assert_equal "citizen", resolve(citizen).audience
        end

        test "wrong mailbox, wrong domain, wrong organisation, revoked and altered tokens do not resolve" do
          address = service_address
          assert_nil resolve(address.sub("prijave+", "other+"))
          assert_nil resolve(address.sub("example.org", "evil.example"))
          assert_nil resolve(address, organization: create_organization)
          assert_nil resolve(tamper(address))
          resolve(address).revoke!
          assert_nil resolve(address)
        end

        test "a service token cannot be presented as a citizen token" do
          assert_nil resolve(service_address.sub("+s-", "+c-"))
        end

        test "address_for never writes and raises when nothing was ensured" do
          assert_raises(ReportMailbox::ReplyAddress::Missing) do
            ReportMailbox::ReplyAddress.address_for(report: @report, audience: "service", correspondents: ["other@city.example"])
          end
          assert_equal 0, ReportReplyCapability.where(report: @report).count
        end

        test "the capability survives the rollback-only decision preview, so confirm sees the same digest" do
          admin = FactoryBot.create(:user, :confirmed, :admin, organization: @organization) # admins hold every operator permission
          # The generated Rails host intentionally has no municipal directory.
          # Seed the actual tenant-scoped verified route; never bypass its guard.
          Setting.put(@organization, Sistem48::DepartmentRouting::NAMESPACE, "putevi", @city.first)
          @report.update!(category: "putevi", severity: "normalan", address: "Harness street 1", latitude: 44.758, longitude: 19.214)
          assert_includes ReportCaseWorkflow.recipients(@organization), @city.first
          assert_equal 0, ReportReplyCapability.where(report: @report, audience: "service").count
          before = @report.reload.attributes
          preview = lambda do
            ReportDecision.new(@report.reload, admin)
                          .preview(action: "send", values: { forwarding_recipient: @city.first }, version: ReportReviewVersion.digest(@report.reload))
          end
          # ReportDecision prepares the capability before its rollback preview.
          # Do not pre-seed it: this assertion catches moving preparation inside
          # the rollback transaction or forgetting that boundary altogether.
          first = preview.call
          capability = ReportReplyCapability.find_by!(report: @report, audience: "service")
          assert capability.correspondent?(@city.first)
          assert_equal before, @report.reload.attributes
          second = preview.call
          assert_equal first[:digest], second[:digest]
          assert_equal [capability.id], ReportReplyCapability.where(report: @report, audience: "service").pluck(:id)
          assert_equal before, @report.reload.attributes
        end

        test "no mailbox configured means no address" do
          Decidim::Bih.report_reply_mailbox = nil
          assert_nil ReportMailbox::ReplyAddress.ensure!(report: @report, audience: "service", correspondents: @city)
          assert_nil ReportMailbox::ReplyAddress.address_for(report: @report, audience: "service", correspondents: @city)
        end
      end
      # Concurrent connections must see committed fixtures; ordinary tests above
      # keep their transactional isolation. Cleanup is restricted to this test's case.
      class ReportReplyAddressConcurrencyTest < ActiveSupport::TestCase
        self.use_transactional_tests = false

        test "concurrent ensure! creates one committed active capability" do
          organization = create_organization
          report = Report.create!(organization:, description: "Concurrent capability fixture", status: "primljeno")
          previous = Decidim::Bih.report_reply_mailbox
          Decidim::Bih.report_reply_mailbox = "prijave@example.org"
          ready = Queue.new
          start = Queue.new
          threads = 2.times.map do
            Thread.new do
              ActiveRecord::Base.connection_pool.with_connection do
                ready << true
                start.pop
                ReportMailbox::ReplyAddress.ensure!(report:, audience: "service", correspondents: ["intake@city.example"])
              end
            end
          end
          2.times { ready.pop }
          2.times { start << true }
          capabilities = threads.map(&:value) # value re-raises worker exceptions
          assert_equal 1, capabilities.map(&:id).uniq.size
          assert_equal 1, ReportReplyCapability.where(report:, audience: "service", revoked_at: nil).count
        ensure
          threads&.each { |thread| thread.join unless thread == Thread.current }
          Decidim::Bih.report_reply_mailbox = previous
          ReportReplyCapability.where(report:).delete_all if report&.persisted?
          report&.destroy!
          # Decidim protects mandatory static pages from ordinary destruction;
          # these pages belong solely to this committed concurrency fixture.
          Decidim::StaticPage.where(organization:).delete_all if organization&.persisted?
          organization&.destroy!
        end
      end
    end
  end
end
