# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require_relative "../../../../../app/services/decidim/bih/concierge/dialogue/state_store"
require_relative "../../../../../app/services/decidim/bih/concierge/web_message"

module Decidim
  module Bih
    module Concierge
      class WebMessageTest < Minitest::Test
        def test_location_language_uses_word_boundaries_and_both_scripts
          ["odavde do Dvorova", "na ovoj lokaciji", "U kojoj sam parking zoni?", "Шта има на овој локацији?", "from here",
           "Sa moje lokacije", "Kako da platim na mojoj lokaciji?", "Od trenutne lokacije",
           "Са моје локације", "На мојој локацији", "from my location"].each do |text|
            assert WebMessage.location_requested?(text), text
          end
          ["status prijave", "kultura", "institucija", "koliko košta parking?", "Bez moje lokacije, molim.",
           "Без моје локације.", "Nemoj koristiti moju trenutnu lokaciju.", "Do not use my location.",
           "Without my location, tell me the fare."].each do |text|
            refute WebMessage.location_requested?(text), text
          end
        end

        def test_only_consented_purpose_metadata_reaches_dialogue_reads
          location = { latitude: 44.7, longitude: 19.2, accuracy: 14, purpose: "current_location",
                       consent: true, provenance: "browser_geolocation" }
          message = WebMessage.new("odavde", location:)

          assert message.location_context?
          assert message.location_consent?
          assert_equal location, message.dialogue_location
          assert_predicate message.dialogue_location, :frozen?
          assert_nil WebMessage.new("odavde", location: location.merge(consent: false)).dialogue_location
          assert_nil WebMessage.new("odavde", location: location.merge(purpose: "tracking")).dialogue_location
          assert_nil WebMessage.new("odavde", location: location.merge(provenance: "model")).dialogue_location
          [-1, 1_000_001, Float::NAN, "invalid", false].each do |accuracy|
            assert_nil WebMessage.new("odavde", location: location.merge(accuracy:)).dialogue_location
          end
        end

        def test_retention_requires_separate_explicit_consent
          location = { latitude: 44.7, longitude: 19.2, accuracy: 14, purpose: "current_location",
                       consent: true, provenance: "browser_geolocation" }
          refute WebMessage.new("odavde", location:).location_retention_consent?
          message = WebMessage.new("odavde", location: location.merge(retain_for_conversation: true))
          assert message.location_retention_consent?
          assert_equal message.dialogue_location, message.public_read_location
          refute WebMessage.new("odavde", location: location.merge(consent: false, retain_for_conversation: true)).location_retention_consent?
        end

        def test_invalid_coordinates_cannot_become_location_context
          [{ latitude: 100, longitude: 20 }, { latitude: 44, longitude: Float::INFINITY }, [44, 19]].each do |location|
            refute WebMessage.new("odavde", location:).location_context?
          end
        end

        def test_credentials_are_detected_without_treating_normal_account_questions_as_secrets
          assert WebMessage.new("Moj kod je 123456").credential_handled?
          refute WebMessage.new("Kako da promijenim lozinku?").credential_handled?
          refute WebMessage.new("1").respond_to?(:sender)
        end
      end
    end
  end
end
