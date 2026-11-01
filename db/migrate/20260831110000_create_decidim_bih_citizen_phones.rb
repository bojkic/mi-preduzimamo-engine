# frozen_string_literal: true

# Trajno čuvanje broja telefona verifikovanog građanina, po odluci naručioca
# (2026-08-31). Do sada je verifikacija čuvala samo SHA256 hash, pa platforma
# nije imala nijedan upotrebljiv SMS kanal.
#
# Jedan red po građaninu. Tabela je PII — pokrivena je retencionim bucket-om
# citizen_phones i isključena iz svih izvoza i analitike.
class CreateDecidimBihCitizenPhones < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_citizen_phones do |t|
      t.references :decidim_user,
                   null: false,
                   foreign_key: { to_table: :decidim_users },
                   index: { unique: true, name: "idx_bih_citizen_phones_user" }
      t.references :decidim_organization,
                   null: false,
                   foreign_key: { to_table: :decidim_organizations },
                   index: { name: "idx_bih_citizen_phones_org" }

      t.string :phone, null: false
      t.datetime :verified_at, null: false

      t.timestamps
    end
  end
end
