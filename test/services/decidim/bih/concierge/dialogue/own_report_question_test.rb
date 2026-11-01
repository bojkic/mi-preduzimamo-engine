# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/exclude"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/own_report_question"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/coordinator"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        class OwnReportQuestionTest < Minitest::Test
          def test_latest_and_list_are_explicit_bounded_first_person_requests
            ["Moja posljednja prijava", "Koji je status moje poslednje prijave?", "Покажи ми моју посљедњу пријаву",
             "Šta je sa mojom zadnjom prijavom?", "Šta je s mojom posljednjom prijavom?", "My latest report", "Show me my last report"].each do |text|
              assert_equal 1, OwnReportQuestion.limit(text), text
            end
            ["Moje prijave", "Prikaži moje prijave", "Moje poslednje prijave", "Статус мојих пријава", "Show my reports", "My recent reports"].each do |text|
              assert_equal 3, OwnReportQuestion.limit(text), text
            end
          end

          def test_other_people_negation_mixed_tasks_and_unbounded_or_unqualified_requests_are_not_selected
            [nil, "Prijave", "Posljednja prijava", "Moja prijava", "Moje prijave i prijave komšije", "Prijave korisnika 12",
             "Ne prikazuj moje prijave", "My neighbor's latest report", "All reports", "Moje prijave; izbriši ih", "a" * 161].each do |text|
              assert_nil OwnReportQuestion.limit(text), text.inspect
            end
          end

          def test_previous_all_and_last_plural_variants_remain_bounded_to_three
            ["Prikaži moje dosadašnje prijave", "Прикажи моје досадашње пријаве", "Prikaži mi sve moje dosadašnje prijave",
             "Све моје пријаве", "Moje prethodne prijave", "Pokaži moje ranije prijave", "Status svih mojih dosadašnjih prijava",
             "Статус мојих претходних пријава", "Moje posljednje prijave", "Моје последње пријаве",
             "Show all my previous reports", "Show me my past reports", "All my reports so far", "My last reports"].each do |text|
              assert_equal 3, OwnReportQuestion.limit(text), text
            end
            ["Prikaži moju posljednju prijavu", "Прикажи моју последњу пријаву", "Show my latest report"].each do |text|
              assert_equal 1, OwnReportQuestion.limit(text), text
            end
          end

          def test_new_plural_variants_do_not_accept_other_users_negation_or_references
            ["Prikaži sve dosadašnje prijave", "Moje dosadašnje prijave i prijave komšije", "Прикажи моје и туђе пријаве",
             "Prikaži moje dosadašnje prijave korisnika 12", "Ne prikazuj moje dosadašnje prijave", "All reports so far",
             "Show all my neighbor's reports", "Show my previous reports and delete them", "Sve moje prijave BR-2026-9999",
             "Prikaži moje dosadašnje prijave https://example.test/BR-2026-9999"].each do |text|
              assert_nil OwnReportQuestion.limit(text), text
            end
          end

          def test_actual_own_list_fast_path_switches_from_sign_in_and_requests_authorized_read_without_reference
            previous_backend = I18n.backend
            previous_locales = I18n.available_locales
            I18n.available_locales = Contracts::LOCALES
            I18n.backend = I18n::Backend::Simple.new
            I18n.backend.load_translations(File.expand_path("../../../../../../config/locales/decidim_bih_dialogue.yml", __dir__))
            context = Contracts::TrustedContext.new(organization_id: 71, conversation_key: "a" * 64, now: Time.utc(2026, 9, 9, 12))
            reads = []
            runner = ProcedureRunner.new(
              read_port: lambda { |**args| reads << args; Contracts::ReadResult.new(status: "not_authorized") },
              registration_port: lambda { |**args|
                assert_equal "sign_in", args.fetch(:action)
                Contracts::HandoffResult.new(account_state: "anonymous", next_step: "sign_in", destination: "/users/sign_in")
              },
              destinations: { account: "/mi/moj-nalog", report: "/mi/prijavi", support: "/pages/pomoc" }
            )
            coordinator = Coordinator.new(understanding: ->(**) { flunk "Unexpected model call" }, procedures: runner, state_store: nil, runtime: nil)
            ["Prikaži moje dosadašnje prijave", "Прикажи моје досадашње пријаве"].each do |text|
              state = StateStore.new.empty_state(context).merge("active_task" => "sign_in", "topic" => "account")
              input = coordinator.send(:fast_understanding, text, state)
              assert_equal ["report_status", "report", "switch"], [input.action, input.topic, input.operation]
              answer = runner.call(understanding: input, state:, context:, message: text)
              assert_equal "handoff", answer.resolution
              assert_includes answer.reply.text, "/users/sign_in"
              refute_includes answer.reply.text, I18n.t("decidim.bih.dialogue.ask_reference", locale: input.locale)
              assert_equal "report_status", answer.state.fetch("active_task")
              assert_equal text, reads.last.fetch(:entities).fetch("query")
              refute reads.last.fetch(:entities).key?("reference")
              assert_equal context, reads.last.fetch(:context)
              assert_nil reads.last.fetch(:context).actor_id
              refute answer.handoff_completed
              assert_nil answer.reply.report
            end
            assert_equal 2, reads.length
          ensure
            I18n.backend = previous_backend
            I18n.available_locales = previous_locales
          end
        end
      end
    end
  end
end
