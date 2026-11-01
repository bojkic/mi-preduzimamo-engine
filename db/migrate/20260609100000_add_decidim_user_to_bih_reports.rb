# frozen_string_literal: true

# Attribute a "Biće riješeno!" report to the logged-in citizen who filed it, so
# the goodwill recognition award (report:20) is auditable and idempotent. The
# column is NULLABLE on purpose: the intake surface is anonymous-first (the same
# endpoint the Viber bot uses), so anonymous/bot reports carry no user and earn
# nothing.
class AddDecidimUserToBihReports < ActiveRecord::Migration[7.2]
  def change
    add_reference :decidim_bih_reports, :decidim_user,
                  null: true, index: true,
                  foreign_key: { to_table: :decidim_users }
  end
end
