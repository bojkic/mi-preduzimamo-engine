# frozen_string_literal: true

# Owner decision D12: MI's newsletter carries platform news to citizens; Odoo
# carries donations, donors and fundraising campaigns.
#
# `Decidim::Admin::NewsletterRecipients` is the ONE audience query core uses -
# the select-recipients screen counts through it and `DeliverNewsletter#recipients`
# sends through it. Narrowing it here is therefore both the preview and the
# dispatch-time recheck, each computed from state as it is at that call rather
# than one copied from the other.
module Decidim
  module Bih
    module Admin
      module NewsletterRecipientsOverride
        def query
          organization = @form.try(:current_organization) || @form.try(:organization)
          return super if organization.blank?

          Decidim::Bih::NewsletterEligibility.narrow(super, organization:)
        end

        private

        def recipients_base_query
          scope = Decidim::User.available.where(organization: @form.current_organization).confirmed.where.not(email: [nil, ""])
          blocked = Messaging::Preference.where(organization: @form.current_organization, topic: "platform_news", state: "blocked")
          scope.where.not(id: blocked.select(:decidim_user_id))
        end
      end
    end
  end
end

Decidim::Admin::NewsletterRecipients.prepend(
  Decidim::Bih::Admin::NewsletterRecipientsOverride
)
