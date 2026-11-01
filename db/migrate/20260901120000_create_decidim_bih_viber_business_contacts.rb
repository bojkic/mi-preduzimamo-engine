# frozen_string_literal: true

# Records that a Decidim user's phone number was proven (through the SMS
# verification flow) and may therefore be addressed by Viber Business Messages.
#
# This is deliberately NOT Decidim::Bih::Viber::Linkage. A Linkage binds an
# opaque Viber *Bot* user id to a phone and only ever comes from the Bot's OTP
# flow. This table is the Business Messages equivalent: phone-addressed, created
# without any Bot involvement, so operator broadcasts and city-service alerts
# still have recipients on a Business-Messages-only deployment.
#
# The MSISDN is stored in the clear because Business Messages is addressed by
# MSISDN and Decidim::Authorization only keeps a SHA-256 of the phone, so the
# number cannot be recovered at send time. Delivery consent stays with the
# mi_city_service_alerts_viber notification setting; retention is swept by
# Decidim::Bih::Privacy::RetentionSweep (bucket: viber_business_contacts).
class CreateDecidimBihViberBusinessContacts < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_viber_business_contacts do |t|
      t.references :decidim_organization,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_organizations }
      t.references :decidim_user,
                   null: false,
                   index: false,
                   foreign_key: { to_table: :decidim_users }

      t.string :phone, null: false
      t.datetime :verified_at, null: false

      t.timestamps
    end

    # One contact per (organization, user): re-verifying a new phone updates the
    # same row rather than accumulating stale numbers.
    add_index :decidim_bih_viber_business_contacts,
              [:decidim_organization_id, :decidim_user_id],
              unique: true,
              name: "idx_bih_viber_business_contacts_on_org_and_user"

    # Supports the retention sweep's cutoff scan.
    add_index :decidim_bih_viber_business_contacts,
              [:decidim_organization_id, :verified_at],
              name: "idx_bih_viber_business_contacts_on_org_and_verified"
  end
end
