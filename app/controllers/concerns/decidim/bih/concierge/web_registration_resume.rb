# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      # Optional host-owned authentication bridge. The engine never creates
      # identities, accepts a completion claim from text or carries old drafts.
      module WebRegistrationResume
        private

        def registration_resume_for(text)
          return unless current_organization_user

          if Dialogue::StateStore.clear_command?(text) || Dialogue::Coordinator.cancelled?(text)
            bridge = registration_handoff_bridge
            bridge.cancel(session:) if bridge.respond_to?(:cancel)
            return
          end
          return if Dialogue::StateStore.sensitive_text?(text)

          registration_handoff_bridge&.consume(session:, context: trusted_dialogue_context, user: current_organization_user)
        rescue StandardError => e
          registration_resume_failure(e)
          nil
        end

        def restore_registration_task(task, message: nil)
          return unless task.is_a?(Hash) && current_organization_user

          context = trusted_dialogue_context
          store = registration_dialogue_store
          # The host has already consumed a backend-authenticated ticket. CAS
          # must still refuse a concurrently populated destination scope.
          restored = task.slice(*Dialogue::StateStore::TASK_KEYS).merge("draft" => nil, "report_handoff_offered" => false)
          state = store.empty_state(context)
          resume_requested = message.nil? || Dialogue::ProcedureRunner::RESUME_COMMANDS.include?(message.to_s.strip.downcase)
          if resume_requested
            state.merge!(restored)
          else
            # A greeting or another question may be the first authenticated
            # turn. Keep the returned work in the existing suspension slot so
            # that handling this new turn cannot silently replace it.
            state["suspended_task"] = restored
            state["locale"] = restored.fetch("locale")
          end
          store.write(context:, state:, expected_version: 0)
        rescue StandardError => e
          registration_resume_failure(e)
          nil
        end

        def prepare_registration_return(reply)
          outcome = reply.dialogue_outcome if reply.respond_to?(:dialogue_outcome)
          return reply unless outcome.is_a?(Dialogue::ProcedureRunner::Result) && outcome.resolution == "handoff"

          bridge = registration_handoff_bridge
          return reply unless bridge

          context = trusted_dialogue_context.with(deadline: Dialogue::TurnBudget.new(timeout: 0.5))
          state = registration_dialogue_store.read(context:)
          return reply unless state && state["version"] == outcome.state.fetch("version") + 1
          return reply unless state.except("version") == outcome.state.except("version")

          bridge.prepare(reply:, action: state["active_task"], context:, state:, session:)
        rescue StandardError => e
          registration_resume_failure(e)
          reply
        end

        def registration_dialogue_store
          Dialogue::StateStore.new
        end

        def registration_handoff_bridge
          brain = concierge
          brain.registration_handoff(organization: current_organization) if brain.respond_to?(:registration_handoff)
        end

        def registration_resume_failure(error)
          Rails.logger.warn("[MilicaRegistrationResume] #{error.class.name}")
        end
      end
    end
  end
end
