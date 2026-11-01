# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A deliberately bounded telemetry contract: no text, identities,
        # entities, provider output, source URLs or exception details.
        module StageTiming
          EVENT = "milica.dialogue_stage"
          STAGES = %w(understanding rendering).freeze

          module_function

          def measure(stage)
            raise ArgumentError, "Unknown dialogue stage" unless STAGES.include?(stage)

            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            status = "completed"
            yield
          rescue StandardError
            status = "failed"
            raise
          ensure
            emit(stage, started, status) if started
          end

          def emit(stage, started, status)
            return unless defined?(ActiveSupport::Notifications)

            duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000).round(2)
            # Instrument the already-sanitized observation, not the execution
            # block: Notifications must never attach an exception message.
            ActiveSupport::Notifications.instrument(EVENT, stage:, status:, duration_ms:)
          rescue StandardError
            nil # Metrics must not change a citizen's answer.
          end
        end
      end
    end
  end
end
