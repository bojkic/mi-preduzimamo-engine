# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/procedure_runner"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Wave 3 package O: six contact-card topics answer from the reviewed
        # host directory whatever the citizen wrote — never a slot question.
        class DirectoryContactTopicsTest < Minitest::Test
          TOPICS = %w(health social_welfare agriculture permits education animals).freeze
          NOW = Time.utc(2040, 9, 13, 20)
          SOURCE_URL = "https://community.example.invalid/authored-health-directory"
          Message = Data.define(:text, :dialogue_location)

          def setup
            I18n.available_locales = Contracts::LOCALES
            I18n.load_path += [File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__)]
            I18n.backend.reload!
            @context = Contracts::TrustedContext.new(organization_id: 1, conversation_key: "b" * 64, now: NOW, capabilities: %w(public_reads))
            @reads = []
            @state = nil
            @runner = ProcedureRunner.new(
              read_port: lambda { |**args|
                @reads << args
                card(args.fetch(:topic))
              },
              registration_port: ->(**) { raise "Unexpected account action" },
              destinations: { report: "/prijavi", account: "/nalog", neighborhood: "/komsiluk", support: "/pomoc" }
            )
          end

          def test_the_six_topics_are_contract_topics_routed_to_the_v1_procedure
            TOPICS.each do |topic|
              assert_includes Contracts::TOPICS, topic
              assert_includes Coordinator::CORE_TOPICS, topic
              assert_equal "service", ProcedureRunner::TOPIC_ANSWER_INTENTS.fetch(topic, "service"), topic
            end
            assert_equal Contracts::TOPICS.uniq, Contracts::TOPICS
          end

          def test_every_wording_is_a_directory_lookup_that_needs_no_area
            TOPICS.each do |topic|
              assert ServiceQuestion.directory_lookup?(topic:, entities: {}), topic
              assert ServiceQuestion.directory_lookup?(topic:, entities: { "query" => "ima li dezurna apoteka nocas", "time_expression" => "nocas" }), topic
              assert ServiceQuestion.directory_lookup?(topic:, entities: { "query" => "koji je broj telefona", "date" => "2040-09-14" }), topic
              assert ServiceQuestion.directory_lookup?(topic:, entities: { "area_query" => "Testni vrt" }), topic
            end
            # The utility publication-source rule is untouched: a live-status
            # question about water still goes to the event feed, area first.
            refute ServiceQuestion.directory_lookup?(topic: "water", entities: { "query" => "ima li vode nocas" })
            refute_includes ServiceQuestion::TOPICS, "health"
          end

          def test_a_pharmacy_question_without_area_or_time_renders_the_card_instead_of_a_slot_question
            result = run_turn("Ima li dežurna apoteka noćas?", topic: "health", entities: { query: "ima li dežurna apoteka noćas", time_expression: "noćas" })

            assert_equal "answered", result.resolution
            assert_equal ["health"], (@reads.map { |read| read.fetch(:topic) })
            assert_nil result.state["pending_slot"]
            assert_includes result.reply.text, "Izmišljena ambulanta +1 202 555 0101"
            assert_includes result.reply.text, SOURCE_URL
            assert_includes result.reply.text, I18n.t("decidim.bih.dialogue.source", source: "Izmišljena ambulanta", locale: "sr")
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.ask_area_query", locale: "sr")
            refute_includes result.reply.text, I18n.t("decidim.bih.dialogue.ask_time_expression", locale: "sr")
          end

          def test_each_topic_answers_from_its_card_with_no_slot_question_or_invented_entity
            TOPICS.each do |topic|
              @state = nil
              result = run_turn("Pitanje za #{topic}", topic:)

              assert_equal "answered", result.resolution, topic
              assert_equal topic, @reads.last.fetch(:topic)
              assert_nil result.state["pending_slot"], topic
              assert_includes result.reply.text, card(topic).facts.first.fetch("text")
              # Task 4: the reader now receives the citizen's OWN question as the
              # query — their words are not an invented entity. Every other slot
              # must still be empty: no area, no day, no category.
              supplied = @reads.last.fetch(:entities).reject { |_key, value| value.to_s.strip.empty? }
              assert_equal({ "query" => "Pitanje za #{topic}" }, supplied, topic)
            end
          end

          private

          def run_turn(text, topic:, entities: {})
            state = @state || StateStore.new.empty_state(@context)
            understanding = Contracts::Understanding.parse(
              "action" => "ask_information", "topic" => topic, "entities" => entities.transform_keys(&:to_s),
              "operation" => "start", "needs_clarification" => false, "secondary" => nil, "locale" => "sr"
            )
            result = @runner.call(understanding:, state:, context: @context, message: Message.new(text:, dialogue_location: nil))
            @state = result.state
            result
          end

          def card(topic)
            text = if topic == "health"
                     "Raspored dežurnih apoteka nemam u provjerenom izvoru. Izmišljena ambulanta +1 202 555 0101."
                   else
                     "Card #{topic}"
                   end
            Contracts::ReadResult.new(
              status: "ok",
              facts: [{ "id" => "service:#{topic}", "kind" => "service_directory", "text" => text,
                        "source_id" => "city_services:#{topic}", "source_label" => "Izmišljena ambulanta",
                        "source_url" => SOURCE_URL, "observed_at" => "2040-09-13" }],
              source: { "id" => "city_services:#{topic}", "label" => "Izmišljena ambulanta", "url" => SOURCE_URL },
              validity: { "reviewed_on" => "2040-09-13", "live_status" => false },
              warnings: ["snapshot_not_live_status"]
            )
          end
        end
      end
    end
  end
end
