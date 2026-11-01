# frozen_string_literal: true

module Decidim
  module Bih
    module InvitationTopicRegistrationOverride
      private

      def accept_resource
        pending = resource_class.find_by_invitation_token(update_resource_params[:invitation_token], true)
        return super unless pending
        return reject_topic_invitation(pending) unless pending.decidim_organization_id == current_organization.id

        expected_token = pending.invitation_token
        pending.with_lock do
          if pending.invitation_token == expected_token
            @initialize_topic_choices = initial_topic_choice?(pending)
            newsletter_at = pending.newsletter_notifications_at
            accepted = super
            complete_invitation_preferences(accepted, newsletter_at:) if accepted.errors.empty? && accepted.invitation_accepted?
            accepted
          else
            reject_topic_invitation(pending)
          end
        end
      rescue ActiveRecord::ActiveRecordError
        raise unless pending

        reject_topic_invitation(pending.reload)
      end

      def show_registration_topic_choice?
        return @initialize_topic_choices if defined?(@initialize_topic_choices)

        initial_topic_choice?(resource)
      end

      def initial_topic_choice?(user)
        user.invitation_accepted_at.nil? && user.sign_in_count.to_i.zero? &&
          !Messaging::Preference.where(organization: user.organization, user:)
                                .exists?(["source <> ? OR state = ?", "organization_default", "blocked"])
      end

      def complete_invitation_preferences(user, newsletter_at:)
        if @initialize_topic_choices
          initialize_invitation_topics(user)
        else
          user.update!(newsletter_notifications_at: newsletter_at)
        end
      end

      def initialize_invitation_topics(user)
        enabled = [true, "1", "true"].include?(update_resource_params[:newsletter_notifications])
        TopicPreferences.set_all!(user, enabled:, source: "account")
        # The old core writer treats the string "0" as truthy. Preserve the
        # compatibility timestamp without allowing it to invert this choice.
        user.update!(newsletter_notifications_at: enabled ? Time.current : nil)
      end

      def reject_topic_invitation(user)
        user.errors.add(:invitation_token, :invalid)
        user
      end
    end
  end
end

Decidim::Devise::InvitationsController.prepend(Decidim::Bih::InvitationTopicRegistrationOverride)

Decidim::Devise::InvitationsController.helper_method(:show_registration_topic_choice?)
