# frozen_string_literal: true

require_relative "pre_model_stages"
require_relative "../web_message"
require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Answer channel/account-scope questions from the server adapter and
        # current trusted scope. Citizen prose is never a channel or identity
        # credential; nothing here links accounts or retains identity facts.
        module TrustedConversationStage
          CHANNEL = /\b(?:messenger\w*|facebook\w*|instagram\w*|viber\w*|whatsapp\w*|web\s+chat)\b/
          module_function

          # Two independent cues are required: the subject and a question about
          # its current scope/evidence. A channel keyword alone cannot own a turn.
          SUBSTANTIVE_REQUEST = /\b(?:prijav\w*\s+(?:problem|ostecenj\w*|kvar\w*)|prijavi|predaj|posalji|salji|povezi|odvezi|obrisi|odjavi|registruj|potvrdi\s+(?:slanje|prijavu)|status\s+prijave|kod\s+za\s+prijavu)\b/
          OTHER_TASK_SUBJECT = /\b(?:prijav(?:a|e|u|om)|bodov\w*|poen\w*|nagrad\w*|glasanj\w*|ocijen\w*|ocjen\w*|autobus\w*|polaz\w*|parking\w*|lozink\w*|fotograf\w*)\b/
          ACCOUNT = /\b(?:nalog\w*|racun\w*|identitet\w*)\b/
          QUESTION = /\b(?:da\s+li|jesi\s+li|je\s+li|jesam\s+li|vidis\s+li|prepoznajes\s+li|imam\s+li)\b/
          ACCOUNT_RELATION = /\b(?:povezan\w*|prijavljen\w*|pristup\w*|prepoznaj\w*|identitet\w*)\b/

          def question?(text)
            return false unless text.is_a?(String) && text.length <= 240

            query = Text.fold(text)
            return false if SUBSTANTIVE_REQUEST.match?(query) || OTHER_TASK_SUBJECT.match?(query)
            return true if current_channel_question?(query)
            return true if /\A(?:kako\s+(?:znam|mogu\s+znati)|da\s+li\s+mogu\s+provjeriti)\s+da\s+li\s+sam\s+(?:registrovan[ao]?|prijavljen[ao]?)\z/.match?(query)
            return false unless CHANNEL.match?(query)

            return true if ACCOUNT.match?(query) && QUESTION.match?(query) && ACCOUNT_RELATION.match?(query)
            return true if /\b(?:ime|nadimak|profil)\b/.match?(query) &&
                           /\b(?:nije\s+dokaz|ne\s+(?:dokazuje|potvrdjuje)|ne\s+znaci)\b/.match?(query) &&
                           /\b(?:nalog\w*|identitet\w*|prijavljen\w*)\b/.match?(query)

            # A citizen explicitly contrasts the claimed app with the app they
            # opened. Merely mentioning two apps, e.g. for delivery, is not enough.
            query.scan(CHANNEL).uniq.length >= 2 &&
              /\b(?:ali|zapravo|stvarno)\s+(?:sam\s+)?(?:otvorio|otvorila|koristim|pisem|razgovaram)(?:\s+[a-z]+){0,4}\s+#{CHANNEL}\z/.match?(query)
          end

          def current_channel_question?(query)
            query.match?(/\A(?:na|u|preko)\s+(?:kojem|kojeg|kojim|kom)\s+(?:sam\s+)?(?:stvarno\s+|zapravo\s+)?kanal\w*(?:\s+(?:sada|sad|trenutno|pisem|razgovaramo|razgovaram|sam|ovdje|ovde)){0,4}\z/) ||
              query.match?(/\Akoji\s+(?:je\s+)?(?:stvarni\s+|trenutni\s+)?kanal\s+(?:ovog\s+)?(?:razgovora|koristimo|koristim)\z/) ||
              query.match?(/\A(?:prilagodi\s+se|odgovori\s+prema|uzmi\s+u\s+obzir)\s+(?:stvarn\w*|trenutn\w*)\s+kanal\w*\z/)
          end

          def result_for(turn)
            return unless question?(turn.text)
            return if turn.message.respond_to?(:image_url) && turn.message.image_url
            return if turn.message.respond_to?(:latitude) && turn.message.latitude

            locale = turn.text.match?(/\p{Cyrillic}/) ? "sr-Cyrl" : turn.state.fetch("locale", "sr")
            # WebMessage is constructed by the authenticated web controller.
            # Unknown adapters remain unknown; no channel is inferred from text.
            channel_key = turn.message.is_a?(WebMessage) ? "trusted_channel_web" : "trusted_channel_unknown"
            actor_key = turn.context.actor_id && turn.context.organization_id ? "trusted_account_present" : "trusted_account_absent"
            text = [channel_key, actor_key].map { |key| I18n.t("decidim.bih.dialogue.#{key}", locale:) }.join(" ")
            reply = Responder::Reply.new(text:, report: nil, answer_intent: "privacy", tone: "core", locale:)
            ProcedureRunner::Result.new(state: turn.state, reply:, resolution: Resolution::ANSWERED,
                                        fact_ids: [], handoff_offered: false, handoff_completed: false)
          end
        end

        PreModelStages.register("trusted_conversation_scope", before: "public_information_card") do |turn|
          TrustedConversationStage.result_for(turn)
        end
      end
    end
  end
end
