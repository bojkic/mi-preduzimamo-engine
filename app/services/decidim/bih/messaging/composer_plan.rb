# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # The CONTENT section of the shared composer: one row per channel, each
      # naming the group that governs it and the content variant the registry
      # says that channel carries.
      #
      # It exists so that no admin page ever writes a channel's content rule
      # down a second time. The registry already records that a WhatsApp report
      # copy is `reference_and_status_only` while the Viber one is
      # `full_status_text`; a page that repeats that in ERB is a copy that goes
      # stale without anybody noticing, and the operator is then shown a
      # preview of a message the platform does not send.
      #
      # A channel the class cannot carry is REPORTED as unsupported. It is
      # never given another group's variant so the row looks complete.
      #
      # Plain Ruby: no Rails. It reads the registry and nothing else — no
      # database, no provider, no preference.
      module ComposerPlan
        module_function

        # @param message_class [String] a REGISTRY key, never a topic name
        # @param channels [Array<String>, nil] nil means every channel the class declares
        # @param contents [Hash] channel => the text that channel would carry
        # @return [Hash] { message_class:, purpose:, priority:, variants: [...] }
        def for(message_class:, channels: nil, contents: {})
          entry = MessageClass.fetch(message_class.to_s)
          channels = (channels || entry.channels).map(&:to_s)
          contents = (contents || {}).transform_keys(&:to_s)

          {
            message_class: entry.key,
            purpose: entry.purpose,
            priority: entry.priority,
            external_boundary: entry.external_boundary?,
            variants: channels.map { |channel| variant_row(entry, channel, contents) }
          }
        end

        def variant_row(entry, channel, contents)
          group = entry.group_for(channel)

          return { channel:, group: nil, variant: nil, content: nil, supported: false, reason: :unsupported_channel } if group.nil?

          {
            channel:,
            group: group[:name],
            variant: variant_for(group, channel),
            content: contents[channel],
            supported: true,
            reason: nil
          }
        end

        # The per-channel override first, the group default second. Exactly the
        # lookup `DeliveryGroup#content_variant_for` performs, against the
        # registry spec rather than a built group, because the composer runs
        # before any recipient exists.
        def variant_for(group, channel)
          (group[:content_variant_by_channel] || {})[channel] || group[:content_variant]
        end
      end
    end
  end
end
