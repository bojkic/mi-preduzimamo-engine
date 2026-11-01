# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/civic_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class CivicQuestionTest < Minitest::Test
          EARNING_QUESTIONS = [
            "kako da zaradim bodove",
            "Kako da zaradim bodove?",
            "kako zaraditi bodove",
            "kako mogu da osvojim bodove",
            "kako se dobijaju bodovi",
            "kako se skupljaju bodovi zajedništva",
            "kako funkcionišu bodovi",
            "šta donosi bodove",
            "gdje da skupim poene",
            "kako do bodova",
            "koliko bodova nosi prijava",
            "како да зарадим бодове"
          ].freeze

          BALANCE_QUESTIONS = ["moji bodovi", "koliko imam bodova", "koliko bodova imam", "moj rang", "koji sam nivo"].freeze

          def test_earning_questions_route_to_the_goodwill_earning_read
            EARNING_QUESTIONS.each do |text|
              read = CivicQuestion.classify(text)

              assert read, text
              assert_equal "ask_information", read.fetch(:action), text
              assert_equal "goodwill", read.fetch(:topic), text
              assert_equal({ "query" => text, "category" => "earn" }, read.fetch(:entities), text)
              assert CivicQuestion.earning?(text), text
            end
          end

          # Task 6 gave the balance its own deterministic route. It is still
          # emphatically NOT the earning schedule — that distinction is what
          # this test has always guarded — but it is no longer left to the
          # model, which classified it as `rewards` and answered with the
          # catalogue. Selection detail lives in personal_read_routes_test.rb.
          def test_balance_questions_stay_on_the_personal_balance_path
            BALANCE_QUESTIONS.each do |text|
              read = CivicQuestion.classify(text)

              assert_equal "goodwill", read&.fetch(:topic), text
              assert_equal "balance", read.dig(:entities, "category"), text
              refute CivicQuestion.earning?(text), text
            end
          end

          def test_earning_pattern_ignores_unrelated_and_oversized_text
            assert_nil CivicQuestion.classify("kako da prijavim problem sa bodovima na cesti")
            assert_nil CivicQuestion.classify("kako da zaradim bodove #{"a" * 160}")
            assert_nil CivicQuestion.classify(nil)
            refute CivicQuestion.earning?(nil)
          end

          INVITATION_QUESTIONS = [
            "Jesam li pozvan na 17.9?",
            "jesam li pozvana na lansiranje",
            "Da li sam pozvan?",
            "imam li pozivnicu",
            "Imam li pozivnicu za lansiranje?",
            "da li imam pozivnicu",
            "Da li sam dobio pozivnicu?",
            "jesam li dobila pozivnicu",
            "jel mi stigla pozivnica",
            "gdje je moja pozivnica",
            "moja pozivnica",
            "status moje pozivnice",
            "koji je moj broj rezervacije",
            "kad je lansiranje",
            "Kada je lansiranje?",
            "Milica, imam li pozivnicu?",
            "Јесам ли позван на 17.9?",
            "имам ли позивницу"
          ].freeze

          KOMSILUK_QUESTIONS = [
            "koji je moj komšiluk",
            "Koji je moj komšiluk?",
            "u kom sam komšiluku",
            "U kojem sam komšiluku?",
            "gdje sam prijavljen",
            "gde sam prijavljena",
            "koji komšiluk sam izabrao",
            "Da li sam izabrao svoj komšiluk?",
            "jesam li odabrala komšiluk",
            "moj komšiluk",
            "koja je moja mjesna zajednica",
            "u kojoj sam mz",
            "Који је мој комшилук?",
            "у ком сам комшилуку"
          ].freeze

          def test_invitation_questions_route_to_the_own_state_read
            INVITATION_QUESTIONS.each do |text|
              read = CivicQuestion.classify(text)

              assert read, text
              assert_equal "ask_information", read.fetch(:action), text
              assert_equal "goodwill", read.fetch(:topic), text
              assert_equal({ "query" => text, "category" => "invitation" }, read.fetch(:entities), text)
              assert_equal "invitation", CivicQuestion.own_state(text), text
              refute CivicQuestion.earning?(text), text
            end
          end

          def test_komsiluk_questions_route_to_the_own_state_read
            KOMSILUK_QUESTIONS.each do |text|
              read = CivicQuestion.classify(text)

              assert read, text
              assert_equal "ask_information", read.fetch(:action), text
              assert_equal "goodwill", read.fetch(:topic), text
              assert_equal({ "query" => text, "category" => "komsiluk" }, read.fetch(:entities), text)
              assert_equal "komsiluk", CivicQuestion.own_state(text), text
            end
          end

          def test_own_state_is_a_whole_utterance_match_and_leaves_other_reads_alone
            [
              "imam pozivnicu", "pozivnica", "kako do pozivnice", "sta ima u mom komsiluku",
              "prijavi problem u mom komsiluku", "ima li obavjestenja na tabli mog komsiluka",
              "moji bodovi", "koliko imam bodova", "kako da zaradim bodove", "ko je predsjednik mz Janja",
              "imam li pozivnicu #{"a" * 160}", nil, 42
            ].each do |text|
              assert_nil CivicQuestion.own_state(text), text.inspect
            end
            assert_equal "earn", CivicQuestion.classify("kako da zaradim bodove").fetch(:entities).fetch("category")
            assert_equal "choose_area", CivicQuestion.classify("ko je predsjednik mz Janja").fetch(:action)
            # A balance question is a read of the citizen's own row, but it is
            # not one of the two OWN-STATE categories; Task 6 routes it separately.
            assert_equal "balance", CivicQuestion.classify("moji bodovi").dig(:entities, "category")
          end

          def test_pharmacy_and_health_centre_questions_select_the_health_card_without_the_model
            ["ima li dezurna apoteka nocas", "Ima li dežurna apoteka noćas?", "koja apoteka radi nocas", "dezurna apoteka",
             "gdje je dom zdravlja", "Има ли дежурна апотека ноћас", "ima li neka apoteka otvorena u nedjelju", "apoteka"].each do |text|
              read = CivicQuestion.classify(text)
              assert_equal "ask_information", read&.fetch(:action), text
              assert_equal "health", read.fetch(:topic), text
              assert_equal text, read.fetch(:entities).fetch("query"), text
            end
            ["ima li vode u Dvorovima", "apoteka mi je prodala pogresan lijek i hocu da prijavim", "kad se odvozi smece"].each do |text|
              read = CivicQuestion.classify(text)
              refute_equal "health", read&.fetch(:topic), text
            end
          end

          # M-1: the city-service keyword matchers compare by SUBSTRING and
          # "pozivnicu" contains "poziv", so an invitation question could be
          # answered with a Grad Bijeljina public call — b2c19 was given an SME
          # call's 17.09.2026 deadline for the 16.09. invitation cutoff. Pinning
          # the topic removes the model's chance to make that substitution.
          def test_a_launch_utterance_is_pinned_to_the_launch_topic
            ["kako do pozivnice", "koliko je ostalo pozivnica", "sta ako izgubim pozivnicu",
             "kako izgleda lansiranje", "ko sve dobija pozivnicu", "kako se boduje trka komsiluka"].each do |text|
              read = CivicQuestion.classify(text)

              assert_equal "ask_information", read&.fetch(:action), text
              assert_equal "launch", read.fetch(:topic), text
              assert_equal({ "query" => text }, read.fetch(:entities), text)
            end
          end

          # An explicit public-call term means the citizen really did ask about
          # a konkurs; the public-calls reader keeps those.
          def test_the_launch_pin_declines_an_explicit_public_call_question
            ["ima li otvorenih javnih poziva", "do kada traje konkurs za stipendije",
             "javni poziv za subvencije MSP", "kada istice natjecaj za grant"].each do |text|
              refute_equal "launch", CivicQuestion.classify(text)&.fetch(:topic), text
            end
          end

          # The own-state routes are registered first and stay first: reading
          # the citizen's own invitation row is not a campaign-policy question.
          def test_own_state_invitation_reads_still_win_over_the_launch_pin
            ["imam li pozivnicu", "kada je lansiranje platforme"].each do |text|
              read = CivicQuestion.classify(text)

              assert_equal "goodwill", read.fetch(:topic), text
              assert_equal "invitation", read.fetch(:entities).fetch("category"), text
            end
          end

          def test_existing_document_board_and_contact_reads_are_unchanged
            assert_equal "city_service", CivicQuestion.classify("kako da izvadim rodni list").fetch(:topic)
            assert_equal "neighborhood_information", CivicQuestion.classify("ima li obavjestenja na tabli mog komsiluka").fetch(:action)
            contact = CivicQuestion.classify("ko je predsjednik mz Janja")
            assert_equal "choose_area", contact.fetch(:action)
            assert_equal "janja", contact.fetch(:entities).fetch("area_query")
          end
        end
      end
    end
  end
end
