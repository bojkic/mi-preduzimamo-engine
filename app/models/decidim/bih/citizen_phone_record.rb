# frozen_string_literal: true

module Decidim
  module Bih
    # Broj telefona verifikovanog građanina. PII — nikad u logove, izvoze ni
    # analitiku. Čita se i piše ISKLJUČIVO kroz Decidim::Bih::CitizenPhone.
    class CitizenPhoneRecord < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_citizen_phones"
      # Rails 7.2's active_record.set_filter_attributes railtie snapshots
      # config.filter_parameters before app initializers populate it, so
      # filter_attributes stays empty even though :phone is configured
      # elsewhere. Set it explicitly so #inspect and debug-level AR
      # bind-parameter logging never print the raw number.
      self.filter_attributes = ["phone"]

      belongs_to :user, class_name: "Decidim::User", foreign_key: "decidim_user_id"
      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      validates :phone, presence: true
      validates :decidim_user_id, uniqueness: true
    end
  end
end
