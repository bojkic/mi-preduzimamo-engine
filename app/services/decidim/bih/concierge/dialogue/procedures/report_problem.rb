# frozen_string_literal: true

require_relative "../own_report_question"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        module Procedures
          module ReportProblem
            def self.call(turn)
              return read_status(turn) if turn.action == "report_status"
              return turn.clarify("description", "ask_description") unless turn.entities["description"]
              return turn.clarify("area_query", "ask_area_query") unless turn.has_location?

              answer = turn.t("report_handoff", url: turn.destination("report"))
              facts = []
              if turn.location
                result = turn.read
                if result.status == "ok"
                  # Reuse the source-aware renderer; only public summaries come
                  # through the authorized duplicate port, never exact GPS.
                  rendered_text, facts = turn.render_duplicate_facts(result)
                  answer = "#{rendered_text}\n\n#{answer}" unless rendered_text.empty?
                elsif %w(unavailable unreviewed stale).include?(result.status)
                  answer = "#{turn.t("duplicate_unavailable")}\n\n#{answer}"
                end
              end
              turn.state["report_handoff_offered"] = true
              turn.finish(answer, resolution: "handoff", facts:, offered: true)
            end

            def self.read_status(turn)
              query = turn.message.respond_to?(:text) ? turn.message.text.to_s : turn.message.to_s
              if (ProcedureRunner::RESUME_COMMANDS.include?(query.strip.downcase) || OwnReportQuestion.correction?(query) || OwnReportQuestion.reference_missing?(query)) && !turn.entities["reference"]
                query = turn.entities["query"].to_s
              end
              if OwnReportQuestion.limit(query)
                # A current own-list request supersedes a retained reference.
                # The port still enforces real tenant/actor read authority.
                turn.state["entities"].delete("reference")
                turn.state["entity_provenance"].delete("reference")
                turn.state["entities"]["query"] = query[0, 160]
                turn.state["entity_provenance"]["query"] = "citizen"
              elsif !turn.entities["reference"]
                return turn.clarify("reference", "ask_reference")
              end
              result = turn.read
              return turn.handoff(action: "sign_in") if result.status == "not_authorized" && turn.context.actor_id.nil?

              turn.render_read(result)
            end
          end
        end
      end
    end
  end
end
