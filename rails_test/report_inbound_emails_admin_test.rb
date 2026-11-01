# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class ReportInboundEmailsAdminTest < ActiveSupport::TestCase
        test "mailbox management is an explicit triager permission" do
          assert_includes OperatorRole::ROLE_PERMISSIONS.fetch("report_triager"), "reports_mailbox_manage"
          refute_includes OperatorRole::ROLE_PERMISSIONS.fetch("analytics_viewer"), "reports_mailbox_manage"
        end
        test "approved senders retain encrypted addresses and can be deactivated" do
          organization = create_organization
          sender = ReportServiceSender.create!(organization:, email: "city@city.example", label: "City")
          assert_equal "city@city.example", sender.reload.email
          refute_includes sender.email_ciphertext, "city@city.example"
          assert_equal "***@city.example", sender.masked_email
          sender.update!(active: false)
          refute ReportServiceSender.active.exists?(sender.id)
        end
      end
    end
  end
end
