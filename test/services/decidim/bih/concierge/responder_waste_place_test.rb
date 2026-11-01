# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string"
require_relative "../../../../../app/services/decidim/bih/concierge/responder"

module Decidim
  module Bih
    module Concierge
      # The legacy brain is still live: it is the whole Viber Bot, and inside
      # the dialogue it is the secondary read adapter for the `waste` intent.
      # A schedule that matched a place but could not confirm it for this query
      # is a QUESTION; rendering it as "nemam podatak" would turn "which of
      # these did you mean?" into "no such record".
      class ResponderWastePlaceTest < Minitest::Test
        Schedule = Struct.new(:days, :resolution, keyword_init: true) do
          def collection_days_for(_query) = days

          def resolution_for(_query) = resolution
        end
        # A host whose schedule predates +resolution_for+ must keep answering
        # exactly as it did.
        LegacySchedule = Struct.new(:days, keyword_init: true) do
          def collection_days_for(_query) = days
        end

        class HostFreeResponder < Responder
          attr_accessor :schedule

          def initialize(schedule)
            @schedule = schedule
          end

          def reply_for(query) = waste_reply_text(query)

          private

          def waste_schedule = @schedule

          def t(key, **) = key

          def localize(text) = text

          def waste_source_note = nil
        end

        def test_a_confirmed_place_still_answers_with_its_days
          responder = HostFreeResponder.new(Schedule.new(days: %w(ponedjeljak), resolution: { status: :ok }))

          assert_equal "waste.found", responder.reply_for("Balkanska")
        end

        def test_an_unconfirmed_place_asks_which_area_instead_of_denying_the_record
          responder = HostFreeResponder.new(Schedule.new(days: nil, resolution: { status: :ambiguous, warning: "place_in_query_not_confirmed" }))

          assert_equal "waste.ask_area", responder.reply_for("Bijelina, Dvorovi")
        end

        def test_a_place_the_schedule_holds_nothing_for_is_still_reported_as_not_found
          responder = HostFreeResponder.new(Schedule.new(days: nil, resolution: { status: :unknown }))

          assert_equal "waste.not_found", responder.reply_for("Atlantida")
        end

        def test_a_schedule_without_a_resolution_keeps_its_previous_answers
          responder = HostFreeResponder.new(LegacySchedule.new(days: nil))

          assert_equal "waste.not_found", responder.reply_for("Atlantida")
        end
      end
    end
  end
end
