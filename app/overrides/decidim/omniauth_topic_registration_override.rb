# frozen_string_literal: true

module Decidim
  module Bih
    # Decidim 0.32.2 create_or_find_user, with topic initialization exclusively
    # in the new-account branch, before any welcome delivery. Existing account
    # linking and sign-in must never reset notification choices.
    module OmniauthTopicRegistrationOverride
      private

      # Core 0.32 initializes the user before its identity transaction. Keep
      # user creation and notification choices atomic if initialization fails.
      def create_or_find_user
        ActiveRecord::Base.transaction(requires_new: true) { create_or_find_user_with_topics }
      end

      def create_or_find_user_with_topics
        @user = User.find_or_initialize_by(
          email: verified_email,
          organization:
        )

        if @user.persisted?
          # If user has left the account unconfirmed and later on decides to sign
          # in with omniauth with an already verified account, the account needs
          # to be marked confirmed.
          if !@user.confirmed? && @user.email == verified_email
            @user.skip_confirmation!
            @user.after_confirmation
          end
          @user.tos_agreement = "1"
          @user.save!
        else
          @user.email = (verified_email || form.email)
          @user.name = form.name.gsub(Decidim::CreateOmniauthRegistration::REGEXP_SANITIZER, "")
          @user.nickname = form.normalized_nickname
          @user.newsletter_notifications_at = form.newsletter_at
          @user.password = SecureRandom.hex
          attach_avatar(form.avatar_url) if form.avatar_url.present?
          @user.tos_agreement = form.tos_agreement
          @user.accepted_tos_version = Time.current
          raise NeedTosAcceptance if @user.tos_agreement.blank?

          @user.skip_confirmation! if verified_email
          @user.save!
          Decidim::Bih::TopicPreferences.set_all!(@user, enabled: form.newsletter == true, source: "account")
          @user.after_confirmation if verified_email
        end
      end
    end
  end
end

Decidim::CreateOmniauthRegistration.prepend(Decidim::Bih::OmniauthTopicRegistrationOverride)
