# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # Which policy actually runs, per organization and per message class.
      #
      # Three layers, the same shape the rest of this engine already uses:
      #   DEFAULT (legacy) → host config (Decidim::Bih.messaging_modes)
      #                    → per-organization Decidim::Bih::Setting (namespace "messaging").
      #
      # Read path and latency, stated rather than assumed: an instance loads the
      # organization's namespace ONCE and is a snapshot. A worker builds one per
      # job, so a flag change takes effect on the next job rather than halfway
      # through one — there is no process-level cache to go stale and no restart
      # to wait for. Host config is read at boot like every other
      # `config_accessor`, so changing THAT does need a restart.
      #
      # Two independent controls, because they answer different questions:
      #   mode              which evaluation runs (legacy / compatibility / target)
      #   dispatch_disabled which enrolled senders may act at all
      # Disabling dispatch must not require also rolling a mode back.
      class Modes
        LEGACY = "legacy"
        COMPATIBILITY = "compatibility"
        TARGET = "target"
        ALL = [LEGACY, COMPATIBILITY, TARGET].freeze
        DEFAULT = LEGACY
        NAMESPACE = "messaging"
        DEFAULT_KEY = "default"

        def initialize(organization: nil, settings: nil)
          @organization = organization
          @settings = settings
        end

        # A producer that is not enrolled in the registry can never be anything
        # but legacy, whatever a setting says. Enrolment is a code decision;
        # a runtime flag may only move an already-enrolled class.
        def for(message_class)
          entry = MessageClass.find(message_class.to_s)
          return LEGACY unless entry&.enrolled?

          candidate = setting("mode.#{message_class}") || host_mode(message_class.to_s) ||
                      setting("mode.#{DEFAULT_KEY}") || host_mode(DEFAULT_KEY) || DEFAULT
          ALL.include?(candidate.to_s) ? candidate.to_s : DEFAULT
        end

        # Independently scoped: `true` means an enrolled sender must not act,
        # regardless of which mode it would have evaluated under.
        def dispatch_disabled?(message_class)
          truthy?(setting("dispatch_disabled.#{message_class}")) ||
            truthy?(setting("dispatch_disabled.#{DEFAULT_KEY}"))
        end

        def snapshot
          settings.dup
        end

        private

        attr_reader :organization

        def settings
          @settings ||= Decidim::Bih::Setting.namespace_for(organization, NAMESPACE)
        rescue StandardError
          # A settings read must never be the reason a decision cannot be made;
          # falling back to the default is the safe direction here, because the
          # default is "legacy", i.e. "change nothing".
          {}
        end

        def setting(key)
          value = settings[key]
          value.nil? || (value.respond_to?(:empty?) && value.empty?) ? nil : value
        end

        def host_mode(key)
          configured = Decidim::Bih.messaging_modes
          return nil unless configured.is_a?(Hash)

          value = configured[key] || configured[key.to_sym]
          value&.to_s
        end

        def truthy?(value)
          [true, "1", "true", "TRUE", 1].include?(value)
        end
      end
    end
  end
end
