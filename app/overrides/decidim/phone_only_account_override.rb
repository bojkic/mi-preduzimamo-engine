# frozen_string_literal: true

module Decidim
  module Bih
    module PhoneOnlyAccountOverride
      def phone_only_registration?
        extended_data.to_h["mi_phone_only_registration"] == true && !admin? && !managed? && roles.blank? &&
          invitation_token.blank? && officialized_at.blank? && !RegisterWithPhone.send(:space_role_holder?, self)
      end

      def normalize_phone_only_blank_email
        self.email = "" if phone_only_registration? && email.blank?
      end

      def email_required?
        return false if phone_only_registration? && email.blank?

        super
      end
    end

    module PhoneOnlyAccountFormOverride
      def email
        super.to_s.strip.downcase
      end

      private

      def validate_old_password
        user = context.current_user
        if user.phone_only_registration? && user.email.blank? && email.present? && password.blank?
          authorization = Decidim::Authorization.find_by(user:, name: "sms")
          return true if authorization&.granted? && !authorization.expired?
        end

        super
      end

      def phone_only_blank_email?
        context.current_user&.phone_only_registration? && context.current_user.email.blank? && email.blank?
      end

      def unique_email
        return true if phone_only_blank_email?

        super
      end
    end

    module PhoneOnlyAccountUpdateMailerOverride
      def notify(user, updates)
        return ActionMailer::Base::NullMail.new if user.email.blank?

        super
      end
    end
  end
end

unless Decidim::User < Decidim::Bih::PhoneOnlyAccountOverride
  Decidim::User.prepend(Decidim::Bih::PhoneOnlyAccountOverride)
  Decidim::User.before_validation :normalize_phone_only_blank_email
  # Core combines nickname and email in one validator. Preserve nickname and
  # every nonblank email constraint; only marked, plain citizens may omit email.
  combined_validators = Decidim::User.validators.select do |validator|
    validator.is_a?(ActiveRecord::Validations::UniquenessValidator) && validator.attributes == [:email, :nickname]
  end
  combined_validators.each do |validator|
    Decidim::User.skip_callback(:validate, :before, validator)
    Decidim::User._validators.each_value { |validators| validators.delete(validator) }
  end
  Decidim::User.validates :nickname, uniqueness: { scope: :organization }, unless: -> { deleted? || managed? || nickname.blank? }
  Decidim::User.validates :email, uniqueness: { scope: :organization }, unless: -> { deleted? || managed? || nickname.blank? || (phone_only_registration? && email.blank?) }

  Decidim::AccountForm.prepend(Decidim::Bih::PhoneOnlyAccountFormOverride)
  Decidim::AccountForm.validators.select { |validator| validator.attributes == [:email] }.each do |validator|
    Decidim::AccountForm.skip_callback(:validate, :before, validator)
    Decidim::AccountForm._validators[:email].delete(validator)
  end
  Decidim::AccountForm.validates :email, presence: true, "valid_email_2/email": { disposable: true }, unless: :phone_only_blank_email?
  # Keep this boundary on the mailer. Account-command wrappers may alias
  # send_update_summary! during boot; prepending it before such an alias creates
  # a super/alias loop for ordinary email accounts (Decidim Awesome timezone).
  Decidim::UserUpdateMailer.singleton_class.prepend(Decidim::Bih::PhoneOnlyAccountUpdateMailerOverride)
end
