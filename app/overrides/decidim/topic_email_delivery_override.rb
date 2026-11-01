# frozen_string_literal: true

module Decidim
  module Bih
    module TopicEmailGenerator
      private

      def send_to_affected_users
        affected_users.each { |recipient| send_email_to(recipient, user_role: :affected_user) }
      end

      def send_to_followers
        affected_ids = affected_users.map(&:id)
        followers.each do |recipient|
          next if affected_ids.include?(recipient.id)

          send_email_to(recipient, user_role: :follower)
        end
      end

      def should_send_email?(recipient)
        return false if extra[:force_email] == false

        Messaging::ProactiveEmail.event_allowed?(recipient, event:, extra:,
                                                            push_event: event_class.types.include?(:notification))
      end
    end

    module TopicNotificationMailer
      def event_received(event, event_class_name, resource, user, user_role, extra) # rubocop:disable Metrics/ParameterLists
        user.reload
        event_class = event_class_name.constantize
        return unless Messaging::ProactiveEmail.event_allowed?(user, event:, extra:,
                                                                     push_event: event_class.types.include?(:notification))
        return if resource.respond_to?(:can_participate?) && !resource.can_participate?(user)

        super
      end
    end

    module TopicDigestMailer
      def digest_mail(user, notification_ids)
        user.reload
        # These are legacy queued digests. Filter every item, rather than
        # allowing one enabled topic to reveal disabled topics in the same mail.
        ids = Decidim::Notification.where(id: notification_ids, user:).filter_map do |notification|
          topic = Messaging::NotificationTopic.for(notification)
          notification.id if Messaging::ProactiveEmail.allowed?(user, topic:) && !WebPush.available_for?(user, topic:)
        end
        return if ids.empty?

        super(user, ids)
      end
    end

    module TopicNewsletterMailer
      def newsletter(user, newsletter, preview = nil)
        return super if preview

        user.reload
        return unless user.decidim_organization_id == newsletter.decidim_organization_id
        return unless Messaging::ProactiveEmail.allowed?(user, topic: :platform_news)

        super
      end
    end

    module TopicNewsletterUnsubscribe
      def call
        return broadcast(:invalid) unless @user

        @user.with_lock do
          TopicPreferences.set!(@user, topic: :platform_news, enabled: false, source: "account")
          @user.update!(newsletter_notifications_at: nil)
        end
        broadcast(:ok, @user)
      rescue ActiveRecord::ActiveRecordError
        broadcast(:invalid)
      end
    end
  end
end

Decidim::EmailNotificationGenerator.prepend(Decidim::Bih::TopicEmailGenerator)
Decidim::NotificationMailer.prepend(Decidim::Bih::TopicNotificationMailer)
Decidim::NotificationsDigestMailer.prepend(Decidim::Bih::TopicDigestMailer)
Decidim::NewsletterMailer.prepend(Decidim::Bih::TopicNewsletterMailer)
Decidim::UnsubscribeSettings.prepend(Decidim::Bih::TopicNewsletterUnsubscribe)
