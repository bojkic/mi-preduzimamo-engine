# frozen_string_literal: true

class ReviewVolunteerApplicationsAndDateAttendance < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_volunteer_signups, :review_status, :string, null: false, default: "pending"
    add_column :decidim_bih_volunteer_signups, :review_source, :string, null: false, default: "application"
    add_column :decidim_bih_volunteer_signups, :reviewed_at, :datetime
    add_reference :decidim_bih_volunteer_signups, :reviewed_by,
                  foreign_key: { to_table: :decidim_users }, index: { name: "idx_bih_signup_reviewer" }
    add_column :decidim_bih_volunteer_signups, :decision_reason, :text
    add_column :decidim_bih_volunteer_signups, :queued_at, :datetime
    add_column :decidim_bih_volunteer_signups, :first_session_at, :datetime
    add_column :decidim_bih_volunteer_signups, :participation_ended_at, :datetime
    add_column :decidim_bih_volunteer_opportunities, :applications_paused_at, :datetime

    # Existing seats keep their current allocation and historical attendance.
    # The host-specific legacy review sweep runs only at its controlled cutover.
    execute <<~SQL
      UPDATE decidim_bih_volunteer_signups
      SET review_status = 'automatic', review_source = 'legacy_auto',
          queued_at = CASE WHEN status = 'waitlisted' THEN created_at ELSE NULL END
      WHERE status IN ('going', 'waitlisted')
    SQL
    execute <<~SQL
      UPDATE decidim_bih_volunteer_signups
      SET review_source = 'legacy_auto', participation_ended_at = updated_at
      WHERE status = 'cancelled'
    SQL
    change_column_default :decidim_bih_volunteer_signups, :status, from: "going", to: "pending"

    add_check_constraint :decidim_bih_volunteer_signups,
                         "status IN ('pending','going','waitlisted','cancelled')",
                         name: "bih_volunteer_signup_status_valid"
    add_check_constraint :decidim_bih_volunteer_signups,
                         "review_status IN ('pending','approved','automatic','rejected','closed')",
                         name: "bih_volunteer_signup_review_valid"
    add_check_constraint :decidim_bih_volunteer_signups,
                         "review_source IN ('application','admin','automatic','legacy_auto','system')",
                         name: "bih_volunteer_signup_source_valid"
    add_check_constraint :decidim_bih_volunteer_signups,
                         "(review_status NOT IN ('rejected','closed') OR status = 'cancelled') AND " \
                         "(status <> 'pending' OR review_status = 'pending') AND " \
                         "(status NOT IN ('going','waitlisted') OR review_status IN ('approved','automatic') OR " \
                         "(review_status = 'pending' AND review_source = 'legacy_auto'))",
                         name: "bih_volunteer_signup_review_allocation_valid"
    add_check_constraint :decidim_bih_volunteer_signups,
                         "status <> 'waitlisted' OR queued_at IS NOT NULL",
                         name: "bih_volunteer_signup_queue_time_valid"
    add_check_constraint :decidim_bih_volunteer_signups,
                         "(status = 'cancelled') = (participation_ended_at IS NOT NULL)",
                         name: "bih_volunteer_signup_end_time_valid"
    add_check_constraint :decidim_bih_volunteer_signups,
                         "review_status <> 'approved' OR (reviewed_at IS NOT NULL AND reviewed_by_id IS NOT NULL)",
                         name: "bih_volunteer_signup_reviewer_valid"
    add_index :decidim_bih_volunteer_signups,
              [:decidim_bih_volunteer_opportunity_id, :review_status, :status, :queued_at, :id],
              name: "idx_bih_signup_review_queue"

    create_table :decidim_bih_volunteer_attendances do |t|
      t.references :decidim_organization, null: false, foreign_key: { to_table: :decidim_organizations },
                    index: { name: "idx_bih_attendance_org" }
      t.references :decidim_bih_volunteer_opportunity, null: false,
                    foreign_key: { to_table: :decidim_bih_volunteer_opportunities },
                    index: { name: "idx_bih_attendance_opportunity" }
      t.references :decidim_bih_volunteer_signup, null: false,
                    foreign_key: { to_table: :decidim_bih_volunteer_signups },
                    index: { name: "idx_bih_attendance_signup" }
      t.references :decidim_user, null: false, foreign_key: { to_table: :decidim_users },
                    index: { name: "idx_bih_attendance_user" }
      t.date :work_date, null: false
      t.string :status, null: false
      t.datetime :confirmed_at, null: false
      t.references :confirmed_by, null: false, foreign_key: { to_table: :decidim_users },
                    index: { name: "idx_bih_attendance_confirmer" }
      t.string :source, null: false
      t.timestamps
    end
    add_index :decidim_bih_volunteer_attendances,
              [:decidim_bih_volunteer_opportunity_id, :decidim_user_id, :work_date],
              unique: true, name: "idx_bih_attendance_day_unique"
    add_check_constraint :decidim_bih_volunteer_attendances,
                         "status IN ('confirmed','absent')",
                         name: "bih_volunteer_attendance_status_valid"
    add_check_constraint :decidim_bih_volunteer_attendances,
                         "source IN ('operator','qr')",
                         name: "bih_volunteer_attendance_source_valid"
  end

  def down
    drop_table :decidim_bih_volunteer_attendances
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_reviewer_valid"
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_queue_time_valid"
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_end_time_valid"
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_review_allocation_valid"
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_source_valid"
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_review_valid"
    remove_check_constraint :decidim_bih_volunteer_signups, name: "bih_volunteer_signup_status_valid"
    remove_index :decidim_bih_volunteer_signups, name: "idx_bih_signup_review_queue"
    change_column_default :decidim_bih_volunteer_signups, :status, from: "pending", to: "going"
    remove_column :decidim_bih_volunteer_opportunities, :applications_paused_at
    remove_column :decidim_bih_volunteer_signups, :first_session_at
    remove_column :decidim_bih_volunteer_signups, :participation_ended_at
    remove_column :decidim_bih_volunteer_signups, :queued_at
    remove_column :decidim_bih_volunteer_signups, :decision_reason
    remove_reference :decidim_bih_volunteer_signups, :reviewed_by, foreign_key: { to_table: :decidim_users }
    remove_column :decidim_bih_volunteer_signups, :reviewed_at
    remove_column :decidim_bih_volunteer_signups, :review_source
    remove_column :decidim_bih_volunteer_signups, :review_status
  end
end
