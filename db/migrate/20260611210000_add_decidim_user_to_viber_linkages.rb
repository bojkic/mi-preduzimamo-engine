# frozen_string_literal: true

# Adds a nullable FK to Decidim::User on Viber::Linkage so that OTP-verified
# senders can be bridged to their Decidim account. The column is NULLABLE because:
#
#   1. Existing linkages (phone-only, no Decidim account) remain valid.
#   2. When OTP verification finds no matching sms-authorized user (or finds
#      multiple — the phone format ambiguity documented in AccountLinking#link!)
#      the linkage stays phone-only (decidim_user_id nil).
#
# ON DELETE NULLIFY: if the Decidim user is destroyed the linkage remains (with
# decidim_user_id = nil) so the privacy retention sweep can still find and
# delete it by its own TTL policy. A cascade-delete would silently drop linkages
# whose phone column is still within the 3-year retention window.
class AddDecidimUserToViberLinkages < ActiveRecord::Migration[7.2]
  def up
    add_reference :decidim_bih_viber_linkages,
                  :decidim_user,
                  null: true,
                  index: true,
                  foreign_key: { to_table: :decidim_users, on_delete: :nullify }
  end

  def down
    remove_reference :decidim_bih_viber_linkages,
                     :decidim_user,
                     foreign_key: { to_table: :decidim_users }
  end
end
