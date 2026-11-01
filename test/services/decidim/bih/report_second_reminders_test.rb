# frozen_string_literal: true

require "test_helper"
require "ostruct"
require_relative "../../../../app/services/decidim/bih/report_second_reminders"

module Decidim
  module Bih
    # Pure policy checks; the host integration suite covers persistence, races,
    # provider state and public/private HTTP visibility with a real database.
    class ReportSecondRemindersTest < Minitest::Test
      def test_message_repeats_the_actual_question_and_private_reply_route
        report = OpenStruct.new(reference: "BR-2026-0008", organization: OpenStruct.new(host: "example.test"),
                                tokenized_status_path: "/biceriseno/prijave/BR-2026-0008/status/private-token")
        question = OpenStruct.new(body: "Which crossing needs a review?")

        text = ReportSecondReminders.message_text(report, question)
        assert_includes text, "BR-2026-0008"
        assert_includes text, question.body
        assert_includes text, "https://example.test/biceriseno/prijave/BR-2026-0008/status/private-token"
        assert_includes text, "3 dana od dostave"
        assert_includes text, "prijava će biti zatvorena"
        assert_includes text, "Istorija prijave ostaje sačuvana"
      end
    end
  end
end
