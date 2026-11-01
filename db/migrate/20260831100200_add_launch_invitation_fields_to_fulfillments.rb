# frozen_string_literal: true

# Polja za automatski izdatu pozivnicu: jednokratni ulazni kod, rok za potvrdu
# dolaska i trag upotrebe koda na vratima.
class AddLaunchInvitationFieldsToFulfillments < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_goodwill_reward_fulfillments, :auto_issued, :boolean,
               null: false, default: false
    add_column :decidim_bih_goodwill_reward_fulfillments, :entry_code, :string
    add_column :decidim_bih_goodwill_reward_fulfillments, :issued_at, :datetime
    add_column :decidim_bih_goodwill_reward_fulfillments, :confirmation_deadline_at, :datetime
    add_column :decidim_bih_goodwill_reward_fulfillments, :attendance_confirmed_at, :datetime
    add_column :decidim_bih_goodwill_reward_fulfillments, :entry_code_used_at, :datetime

    # IDEMPOTENTNOST U BAZI: jedan korisnik = najviše jedna automatski izdata
    # nagrada po ključu, bez obzira na status i na broj paralelnih pokušaja.
    # Parcijalni indeks ne dira ručna preuzimanja (auto_issued = false), gdje
    # građanin smije preuzeti istu nagradu više puta.
    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :decidim_user_id, :reward_key],
              unique: true,
              where: "auto_issued = TRUE",
              name: "idx_bih_auto_issued_one_per_user_reward"

    # Ulazni kod mora biti jedinstven u organizaciji — skener na vratima
    # razrješava tačno jedan red.
    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :entry_code],
              unique: true,
              where: "entry_code IS NOT NULL",
              name: "idx_bih_reward_fulfillments_entry_code"

    # Job koji poništava nepotvrđene pozivnice traži tačno ovaj presjek.
    add_index :decidim_bih_goodwill_reward_fulfillments,
              [:decidim_organization_id, :confirmation_deadline_at],
              where: "auto_issued = TRUE AND attendance_confirmed_at IS NULL",
              name: "idx_bih_launch_invitation_pending_confirmation"
  end
end
