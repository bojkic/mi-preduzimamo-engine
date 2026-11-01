# frozen_string_literal: true

# Makes the phone column on decidim_bih_viber_linkages nullable so that a
# Viber-link-only row (created by ViberVerifyFlow, which binds a Viber sender
# to a Decidim user via a deep-link token) can have phone: nil.
#
# Rationale: the original migration set null: false because every row was
# created by the OTP flow (phone proven by OTP). ViberVerifyFlow creates rows
# from a LoginToken, proving only that the user controls BOTH their logged-in
# Decidim session AND the Viber account — NOT a specific phone. So phone must
# be optional. A nil phone is treated as "no phone" by attributed_phone,
# report forwarding, and the privacy retention sweep (all already guard blank).
class MakeViberLinkagePhoneNullable < ActiveRecord::Migration[7.2]
  def up
    change_column_null :decidim_bih_viber_linkages, :phone, true
  end

  def down
    # Back-fill any nil phones before restoring NOT NULL (otherwise down raises).
    # We use an empty string as a marker; in practice no real row should have nil
    # phone after a down migration — this is purely a safety backstop.
    execute "UPDATE decidim_bih_viber_linkages SET phone = '' WHERE phone IS NULL"
    change_column_null :decidim_bih_viber_linkages, :phone, false
  end
end
