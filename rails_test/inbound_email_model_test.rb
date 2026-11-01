# frozen_string_literal: true

require "test_helper"
module Decidim
  module Bih
    module RailsHarness
      class InboundEmailModelTest < ActiveSupport::TestCase
        def attributes
          { organization: @organization, account: "prijave@example.org", folder: "All", uidvalidity: 1, uid: 1, gm_msgid: "one", internal_date: Time.current, size_bytes: 10, raw: "fixture-secret-body", subject: "fixture-subject" }
        end
        setup { @organization = create_organization }
        test "provider identity deduplicates but RFC Message-ID is not unique" do
          InboundEmail.create!(**attributes, message_id: "shared@example.org")
          assert_raises(ActiveRecord::RecordNotUnique) { InboundEmail.transaction(requires_new: true) { InboundEmail.create!(**attributes, uid: 2) } }
          second = InboundEmail.create!(**attributes, gm_msgid: "two", uid: 2, message_id: "shared@example.org")
          assert_equal "shared@example.org", second.message_id
          assert_equal "fixture-secret-body", second.raw
          refute_includes second.raw_ciphertext, "fixture-secret-body"
        end
        test "one mail can link three reports and history cannot be unset" do
          email = InboundEmail.create!(**attributes, history_only: true, history_reason: "pre_activation")
          3.times do
            report = Report.create!(organization: @organization, description: "Rupa na putu", status: "primljeno")
            email.inbound_email_links.create!(report:, matching_method: "reference", assurance: "association")
          end
          assert_equal 3, email.reports.count
          refute email.update(history_only: false)
        end
      end
    end
  end
end
