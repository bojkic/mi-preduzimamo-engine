# frozen_string_literal: true

# Devise calls after_confirmation on every confirmation, including
# reconfirmation of a changed address (it assigns unconfirmed_email to email
# BEFORE calling this, so the address recorded below is the new one). Record
# the proven address here and, when the host runs phone-first registration,
# deliberately do NOT publish Decidim's welcome notification at e-mail
# confirmation: under phone-first the phone, not the e-mail, is the moment the
# citizen joins, so the welcome belongs on the first granted `sms`
# authorization. That hook is publish_phone_first_welcome_if_verified in
# authorization_referral_override.rb; it publishes the same event, with the
# same payload, that core would have published here. A host with the flag off
# is unaffected and still gets core's welcome at e-mail confirmation.
#
# Skipping super skips the WHOLE core method. In decidim-core 0.31.7
# Decidim::User#after_confirmation (app/models/decidim/user.rb:284-294)
# publishes only the welcome notification, so nothing else is lost — re-check
# that on upgrade before skipping super.
module Decidim
  module Bih
    module UserEmailConfirmationOverride
      def after_confirmation
        Decidim::Bih::EmailConfirmation.mark_confirmed!(self, email)
        return if Decidim::Bih.phone_first_registration

        super
      end
    end
  end
end

Decidim::User.prepend(Decidim::Bih::UserEmailConfirmationOverride)
