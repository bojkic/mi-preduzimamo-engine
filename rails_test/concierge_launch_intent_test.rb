# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Historical launch guidance remains reachable through the real responder
      # without promising new event invitations or exposing account state. The
      # keyword-routed handler must still win over an unrelated report fallback.
      class ConciergeLaunchIntentTest < ActiveSupport::TestCase
        # Minimal inbound message duck type — mirrors the host's own Responder
        # test fixtures (e.g. decidim_app's ResponderGoodwillTest::Message).
        # #image_url/#latitude/#longitude must still RESPOND, even as nil, so
        # report_signal? and its coordinate helpers (which respond_to?-guard
        # per-method) see "no photo/location" rather than falling through the
        # whole handler chain to the report catch-all.
        Message = Struct.new(:text, :image_url, :latitude, :longitude, keyword_init: true) do
          def initialize(text: nil, image_url: nil, latitude: nil, longitude: nil)
            super
          end
        end

        class FakeDirectory
          def search(_query, **) = []
        end

        class FakeWaste
          def collection_days_for(_query) = nil
        end

        class ReportIntentFixture
          def configured? = true

          def classify(_text)
            Decidim::Bih::Concierge::IntentClassifier::Result.new(intent: :report, query: nil)
          end
        end

        setup do
          @organization = create_organization
        end

        def build_responder
          Decidim::Bih::Concierge::Responder.new(
            organization: @organization,
            directory: FakeDirectory.new,
            waste_schedule: FakeWaste.new
          )
        end

        test "launch is a known intent" do
          assert_includes Decidim::Bih::Concierge::IntentClassifier::INTENTS, :launch
          assert_includes Decidim::Bih::Concierge::AnswerIntents::VALUES, "launch"
        end

        test "the launch answer dates the event as historical without announcing a future programme" do
          reply = build_responder.respond(Message.new(text: "Kada i gdje je lansiranje?"))

          assert_includes reply.text, "održano je 17. septembra 2026"
          assert_includes reply.text, "više se ne može zaraditi"
          assert_not_includes reply.text, "Vidimo se"
          assert_equal "launch", reply.answer_intent
        end

        test "the launch answer preserves access to old records without offering a new invitation" do
          reply = build_responder.respond(Message.new(text: "Kako da dobijem pozivnicu?"))

          assert_includes reply.text, "Nova pozivnica za taj događaj više se ne može zaraditi"
          assert_includes reply.text, "Evidenciju ranije izdate pozivnice"
          assert_includes reply.text, Decidim::Bih.public_path("zajednistvo")
          refute_match(/20 bodova|registruj se/i, reply.text)
        end

        test "an anonymous balance request requires sign in without an invitation threshold promise" do
          reply = I18n.with_locale(:sr) { build_responder.respond(Message.new(text: "Koliko bodova imam?")) }

          assert_equal "goodwill", reply.answer_intent
          assert_includes reply.text, "/sr/users/sign_in"
          assert_includes reply.text, Decidim::Bih.public_path("moj-doprinos")
          refute_match(/pozivnic|20 bodova/i, reply.text)
        end

        # A bare venue/date mention is not a launch stem. Without a classifier
        # or photo/location evidence, an otherwise unclassified complaint must
        # remain on the safe help path rather than create a report implicitly.
        test "an unclassified complaint naming the launch venue gets help, not a launch or report" do
          reply = nil
          assert_no_difference "Decidim::Bih::Report.count" do
            reply = build_responder.respond(
              Message.new(text: "Centar za kulturu nema pristup za kolica, treba rampa za invalide")
            )
          end

          assert_equal "help", reply.answer_intent
          refute_equal "launch", reply.answer_intent
          assert_nil reply.report
        end

        test "an enabled report classifier gives form guidance without creating a report" do
          responder = Decidim::Bih::Concierge::Responder.new(
            organization: @organization,
            directory: FakeDirectory.new,
            waste_schedule: FakeWaste.new,
            classifier: ReportIntentFixture.new,
            allow_classifier_text_report: true
          )

          reply = nil
          assert_no_difference "Decidim::Bih::Report.count" do
            reply = responder.respond(
              Message.new(text: "Centar za kulturu nema pristup za kolica, treba rampa za invalide")
            )
          end

          assert_equal "report_guidance", reply.answer_intent
          assert_includes reply.text, Decidim::Bih.public_path("prijave/new")
          assert_nil reply.report
        end
      end
    end
  end
end
