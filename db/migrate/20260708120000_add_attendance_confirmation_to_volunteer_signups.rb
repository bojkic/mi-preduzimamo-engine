# frozen_string_literal: true

class AddAttendanceConfirmationToVolunteerSignups < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_signups, :attendance_confirmed_at, :datetime
    add_column :decidim_bih_volunteer_signups, :attendance_source, :string
    add_reference :decidim_bih_volunteer_signups,
                  :attendance_confirmed_by,
                  foreign_key: { to_table: :decidim_users },
                  index: { name: "idx_bih_volunteer_signups_attendance_by" }

    add_index :decidim_bih_volunteer_signups,
              [:decidim_organization_id, :attendance_confirmed_at],
              name: "idx_bih_volunteer_signups_org_attended"
  end
end
