# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # A Business Message uses the current verified account phone. A legacy
      # Bot link or a stale BusinessContact never takes precedence. Permission
      # remains the caller's separate responsibility.
      module BusinessRecipient
        module_function

        def phone_for(user:, organization_id:)
          return if user.blank? || user.decidim_organization_id != organization_id.to_i

          phone = VerifiedPhone.phone_for(user:, organization: user.organization)
          Linkage.normalize_phone(phone) if phone.present?
        end
      end
    end
  end
end
