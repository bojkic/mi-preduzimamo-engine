# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class ReportMailboxClassifierTest < ActiveSupport::TestCase
        def classify(headers = "", labels: [], own_message_ids: [])
          mail = Mail.read_from_string("From: city@city.example\r\nTo: prijave@example.org\r\nMessage-ID: <fixture@example.org>\r\n#{headers}\r\nBody")
          ReportMailbox::Classifier.call(mail, labels:, own_message_ids:)
        end
        test "labels distinguish platform and staff copies and drafts" do
          assert_equal "outbound_copy", classify(labels: ["\\Sent"], own_message_ids: ["fixture@example.org"])[:classification]
          assert_equal "staff_sent", classify(labels: ["\\Sent"])[:classification]
          assert_equal "draft", classify(labels: ["\\Draft"])[:classification]
        end
        test "auto replies are ignored but bulk correspondence is retained" do
          ["Auto-Submitted: auto-replied\r\n", "X-Autoreply: yes\r\n", "Subject: Automatski odgovor: odsutan\r\n", "Subject: Out of Office: holiday\r\n"].each do |headers|
            assert_equal "auto_reply", classify(headers)[:classification]
          end
          assert_equal "candidate", classify("Auto-Submitted: no\r\n")[:classification]
          assert_equal({ classification: "candidate", no_auto_response: true }, classify("Precedence: bulk\r\n"))
          assert_equal({ classification: "candidate", no_auto_response: true }, classify("List-Id: city.example\r\n"))
        end
      end
    end
  end
end
