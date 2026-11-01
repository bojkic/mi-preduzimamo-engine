# frozen_string_literal: true

require "i18n"
require_relative "account_question"
require_relative "contracts"
require_relative "resolution"
require_relative "procedure_runner"
require_relative "pre_model_stages"
require_relative "../responder"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # The ONE account answer that has to run as a pre-model stage.
        #
        # Everything else about an account is answered inside the registration
        # procedure, which knows the citizen's real account state. This question
        # cannot wait for it: Task 3b's reviewed privacy card matches
        # "moj broj telefona" + "vide" and answers with the privacy policy,
        # which is true, generic, and not an answer to "do other citizens see my
        # number". A specific reviewed answer outranks a general one — the same
        # rule by which that card already declines report privacy — so this
        # registers immediately BEFORE it.
        #
        # It needs no account state (the answer is the same for every citizen),
        # writes no conversation state and makes no model call.
        module AccountPhoneVisibilityStage
          module_function

          def result_for(turn)
            return if turn.message.respond_to?(:image_url) && !turn.message.image_url.nil?
            return if turn.state["draft"] || turn.state["pending_slot"] == "description"
            return unless AccountQuestion.phone_visibility_question?(turn.text)

            locale = locale_for(turn)
            text = I18n.t("decidim.bih.dialogue.account_phone_visibility", locale:, url: account_url)
            return if text.nil? || text.strip.empty?

            reply = Responder::Reply.new(text:, report: nil, answer_intent: "setup", tone: "core")
            ProcedureRunner::Result.new(state: turn.state, reply:, resolution: Resolution::ANSWERED,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end

          def locale_for(turn)
            return "sr-Cyrl" if turn.text.match?(/\p{Cyrillic}/)

            saved = turn.state["locale"]
            Contracts::LOCALES.include?(saved) ? saved : "sr"
          end

          def account_url
            Decidim::Bih::Engine.routes.url_helpers.account_overview_path
          rescue StandardError
            begin
              Decidim::Bih.public_path("moj-nalog")
            rescue StandardError
              "/biceriseno/moj-nalog"
            end
          end
        end

        PreModelStages.register("account_phone_visibility_card", before: "public_information_card") do |turn|
          AccountPhoneVisibilityStage.result_for(turn)
        end
      end
    end
  end
end
