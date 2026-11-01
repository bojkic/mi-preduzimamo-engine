# frozen_string_literal: true

module Decidim
  module Bih
    module CreateRegistrationPhoneFirstOverride
      private

      def create_user
        ActiveRecord::Base.transaction do
          if Decidim::Bih.phone_first_registration
            @user = Decidim::User.new(
              email: form.email, name: form.name, nickname: form.nickname,
              password: form.password, password_updated_at: Time.current,
              organization: form.current_organization, tos_agreement: form.tos_agreement,
              newsletter_notifications_at: form.newsletter_at,
              accepted_tos_version: form.current_organization.tos_version,
              locale: form.current_locale
            )
            @user.skip_confirmation!
            @user.save!
          else
            super
          end
          TopicPreferences.set_all!(@user, enabled: form.newsletter == true, source: "account")
        end
      end
    end
  end
end

Decidim::CreateRegistration.prepend(Decidim::Bih::CreateRegistrationPhoneFirstOverride)
