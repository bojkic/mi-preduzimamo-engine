# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Which enrolled senders may leave their legacy body, per organization and
      # per message class — and whether they may act at all.
      #
      # This is a THIN READER over the Phase 1 store. It defines no mode, owns
      # no setting and invents no key: `Messaging::Modes` already layers the
      # per-organization `Decidim::Bih::Setting` (namespace "messaging") over
      # the host `Decidim::Bih.messaging_modes` config over `legacy`, and
      # already refuses to move a class the registry has not enrolled. Phase 2
      # exists on top of that, not beside it. See
      # host:docs/superpowers/sdd/2026-09-14-comms/phase-2-binding.md.
      #
      # Three things worth stating because they are easy to get backwards:
      #
      #   * There are THREE runtime modes, not four. `shadow` is the registry's
      #     *enrollment state* (`MessageClass::Entry#enrolled?`), not something a
      #     flag can be set to. "In shadow" means registry-enrolled and still
      #     running `legacy`, which is what {shadow_observed?} answers.
      #   * The store's key is `dispatch_disabled`; this reader's question is
      #     `dispatch_enabled?`. The sense is inverted on purpose, because every
      #     caller reads better asking "may I act".
      #   * Every unknown, unrecognised or unreadable input fails CLOSED to
      #     `:legacy` with dispatch disabled. That direction is safe precisely
      #     because it only ever suppresses the ROUTED path: a caller that
      #     cannot read its mode falls back to the legacy body production has
      #     been running all along. A legacy sender must never consult
      #     {dispatch_enabled?} to decide whether to send at all.
      module Enrollment
        MODES = [:legacy, :compatibility, :target].freeze
        DEFAULT_MODE = :legacy

        # Seconds a per-organization mode change can take to become visible to
        # an already running worker. `Modes` loads the namespace once per
        # instance and a worker builds one per job, so a row change is visible
        # to the NEXT job with no restart and no process-level cache to go
        # stale. Recorded rather than guessed: a task that claims a one-flip
        # rollback has to be able to name this number.
        SETTING_REFRESH_LATENCY_SECONDS = 0

        class << self
          # @return [Symbol] one of {MODES}
          def mode(organization:, message_class:, modes: nil)
            return DEFAULT_MODE unless addressable?(organization, message_class)

            raw = snapshot(organization, modes).for(message_class.to_s)
            MODES.include?(raw&.to_sym) ? raw.to_sym : DEFAULT_MODE
          rescue StandardError => e
            report(e, "mode")
            DEFAULT_MODE
          end

          # May an ENROLLED sender act? Independently scoped from {mode} so an
          # operator can stop a routed sender without also rolling its mode back.
          def dispatch_enabled?(organization:, message_class:, modes: nil)
            return false unless addressable?(organization, message_class)

            !snapshot(organization, modes).dispatch_disabled?(message_class.to_s)
          rescue StandardError => e
            report(e, "dispatch_enabled?")
            false
          end

          # The one question an enrolled caller actually asks: "do I route this,
          # or do I run my legacy body?". Both halves read the SAME snapshot, so
          # a flag flip between the two cannot produce a mode and a kill switch
          # that disagree inside one decision.
          def routes?(organization:, message_class:, modes: nil)
            return false unless addressable?(organization, message_class)

            shared = modes || modes_for(organization)
            mode(organization:, message_class:, modes: shared) != DEFAULT_MODE &&
              dispatch_enabled?(organization:, message_class:, modes: shared)
          end

          # Registry enrollment: a code decision, not a runtime flag. A class
          # that is not enrolled here can never be moved off legacy at all.
          def enrolled?(message_class)
            return false if blank?(message_class)

            MessageClass.find(message_class.to_s)&.enrolled? == true
          rescue StandardError => e
            report(e, "enrolled?")
            false
          end

          # Registry-enrolled, still running legacy: Phase 1's observation
          # state. `ShadowCompare` may look; nothing routes.
          def shadow_observed?(organization:, message_class:, modes: nil)
            enrolled?(message_class) &&
              mode(organization:, message_class:, modes:) == DEFAULT_MODE
          end

          def refresh_latency_seconds
            SETTING_REFRESH_LATENCY_SECONDS
          end

          # The host-config layer is a boot-read `config_accessor`, so a task
          # that changes THAT may not describe it as instantly effective.
          def host_config_requires_restart?
            true
          end

          # One snapshot per job is the intended unit; callers that ask several
          # questions should build it once and pass it to both this module and
          # `Policy.decide(modes:)`.
          def modes_for(organization)
            Modes.new(organization:)
          end

          private

          def snapshot(organization, modes)
            modes || modes_for(organization)
          end

          def addressable?(organization, message_class)
            !organization.nil? && !blank?(message_class)
          end

          def blank?(value)
            value.nil? || value.to_s.strip.empty?
          end

          def report(error, operation)
            return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

            Rails.logger.warn("[Messaging::Enrollment] #{operation} failed closed to legacy: #{error.class}")
          end
        end
      end
    end
  end
end
