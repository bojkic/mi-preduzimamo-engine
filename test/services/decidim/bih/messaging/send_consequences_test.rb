# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/messaging/message_class"
require_relative "../../../../../app/services/decidim/bih/messaging/send_consequences"

module Decidim
  module Bih
    module Messaging
      class SendConsequencesTest < Minitest::Test
        STATUS_EMAIL = "report.reporter_status_email"
        STATUS_COPY = "report.author_external_copy"
        POINTS = "goodwill.points_earned"

        def test_it_returns_one_row_per_class_in_the_order_given
          rows = SendConsequences.for([STATUS_EMAIL, STATUS_COPY])
          assert_equal([STATUS_EMAIL, STATUS_COPY], rows.map { |row| row[:key] })
        end

        def test_each_row_carries_the_channels_the_registry_declares
          row = SendConsequences.for([STATUS_COPY]).first
          assert_equal MessageClass.fetch(STATUS_COPY).channels, row[:channels]
          refute_empty row[:channels]
        end

        def test_each_row_names_who_it_reaches
          row = SendConsequences.for([POINTS]).first
          assert_equal MessageClass.fetch(POINTS).recipient_kinds, row[:recipient_kinds]
        end

        # A boundary class is something MI does not send. Promising a send
        # would be worse than saying nothing.
        def test_a_boundary_class_is_flagged_rather_than_promised
          row = SendConsequences.for(["campaign.letter_p11"]).first
          assert row[:external_boundary]
        end

        def test_an_unknown_key_raises_for_a_producer
          assert_raises(MessageClass::UnknownMessageClass) { SendConsequences.for(["no.such.class"]) }
        end

        # A consequences strip must never be the thing that 500s a page an
        # operator needs in order to work a case.
        def test_the_tolerant_reader_drops_an_unknown_key_instead_of_raising
          rows = SendConsequences.tolerant_for(["no.such.class", POINTS])
          assert_equal([POINTS], rows.map { |row| row[:key] })
        end

        def test_no_classes_produce_no_rows
          assert_empty SendConsequences.for([])
          assert_empty SendConsequences.tolerant_for(nil)
        end

        # The strip is derived from the registry, not hand-written per page.
        def test_the_service_hard_codes_no_message_class_key
          source = File.read(File.expand_path("../../../../../app/services/decidim/bih/messaging/send_consequences.rb", __dir__))
          MessageClass.all.each_key do |key|
            refute_includes source, "\"#{key}\"", "#{key} is hard-coded; the registry is the list"
          end
        end
      end
    end
  end
end
