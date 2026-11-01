# frozen_string_literal: true

# Delivery D defines this controller and form. Resolve them during to_prepare
# so the adapter activates automatically once D is present, while older hosts
# without the one-step registration flow keep booting unchanged.
controller = "Decidim::Bih::RegistrationsController".safe_constantize
form = "Decidim::Bih::PhoneRegistrationForm".safe_constantize

controller.prepend(Decidim::Bih::SocialRegistrationPrefill) if
  controller && form && controller.ancestors.exclude?(Decidim::Bih::SocialRegistrationPrefill)
