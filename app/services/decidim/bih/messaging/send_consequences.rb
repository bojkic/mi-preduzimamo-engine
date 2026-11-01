# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # "This action will also send…" — for surfaces whose PURPOSE is not
      # sending.
      #
      # Changing a report's status, awarding points, deciding a reward: each
      # of those sends something, and an operator should know what before they
      # click. What they must NOT get is a bulk-campaign wizard on every
      # operational action. Friction is proportional: a bulk send previews and
      # confirms, a side effect states its consequences and stays one click.
      #
      # Everything is read off the registry. No admin page names a message
      # class, a channel or a recipient kind, because a page that writes those
      # down a second time goes stale silently and then tells an operator
      # something the platform stopped doing.
      #
      # Plain Ruby: no Rails. The registry is the only thing it reads.
      module SendConsequences
        module_function

        # @param message_classes [Array<String>] REGISTRY keys
        # @return [Array<Hash>] one row per class, in the order given
        def for(message_classes)
          Array(message_classes).map { |key| row(MessageClass.fetch(key.to_s)) }
        end

        # Unknown keys are dropped rather than raising, because a consequences
        # strip must never be the thing that 500s an operational page. A key
        # that is genuinely wrong is caught by {for}, which is what the tests
        # and the producers use.
        def tolerant_for(message_classes)
          Array(message_classes).filter_map do |key|
            entry = MessageClass.find(key.to_s)
            row(entry) if entry
          end
        end

        def row(entry)
          {
            key: entry.key,
            purpose: entry.purpose,
            priority: entry.priority,
            recipient_kinds: entry.recipient_kinds,
            channels: entry.channels,
            # A boundary class is something the platform does NOT send. Saying
            # "this will send" about one would be a false promise.
            external_boundary: entry.external_boundary?,
            groups: Array(entry.channel_groups).map { |group| group[:name] }
          }
        end
      end
    end
  end
end
