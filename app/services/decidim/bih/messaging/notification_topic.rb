# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # One classification for proactive delivery. Inbox creation never reads
      # this choice. Explicit server-side producer metadata takes precedence.
      module NotificationTopic
        module_function

        def for(notification)
          return "community_news" if notification.respond_to?(:conversation)

          for_event(notification.respond_to?(:event_name) ? notification.event_name : nil,
                    extra: notification.respond_to?(:extra) ? notification.extra : {})
        end

        def for_event(event_name, extra: {})
          extra ||= {}
          explicit = extra["notification_topic"] || extra[:notification_topic]
          return TopicPreferences.canonical_topic(explicit) if explicit

          event = event_name.to_s
          return "report_updates" if event.start_with?("decidim.events.bih.report_")
          return "neighborhood_info" if event.match?(/komsiluk|local_broadcast|city_service/)
          return "platform_news" if event.match?(/welcome_notification|launch_invitation|operator_role|platform/)

          # Participatory module activity, community contributions, volunteering,
          # goodwill and conversations belong to community news. Unknown future
          # event families use this documented category until explicitly mapped.
          "community_news"
        end
      end
    end
  end
end
