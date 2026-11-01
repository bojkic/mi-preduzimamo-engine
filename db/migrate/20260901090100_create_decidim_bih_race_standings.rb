# frozen_string_literal: true

# Cached race standings. The public leaderboard reads ONLY this table — the
# score is never computed during a request, so launch-night traffic cannot take
# the rest of the platform down with it.
#
# `final` rows are the 14.10. 20:00 snapshot. Once written they are never
# recomputed, so the published final numbers can never drift.
class CreateDecidimBihRaceStandings < ActiveRecord::Migration[7.2]
  def change
    create_table :decidim_bih_race_standings do |t|
      t.references :decidim_organization, null: false, index: false
      t.bigint :komsiluk_id, null: false
      t.string :zona
      t.integer :registered, null: false, default: 0
      t.integer :reports, null: false, default: 0
      t.integer :proposals, null: false, default: 0
      t.integer :score, null: false, default: 0
      t.datetime :reached_at
      t.integer :rank_overall, null: false, default: 0
      t.integer :rank_in_zone, null: false, default: 0
      t.datetime :computed_at, null: false
      # NOT named "frozen": an AR attribute named frozen defines frozen?, which
      # collides with Object#frozen? and raises DangerousAttributeError.
      t.boolean :final, null: false, default: false
      t.timestamps
    end

    add_index :decidim_bih_race_standings,
              [:decidim_organization_id, :komsiluk_id, :final],
              unique: true,
              name: "idx_bih_race_standings_unique"
    add_index :decidim_bih_race_standings,
              [:decidim_organization_id, :final, :rank_overall],
              name: "idx_bih_race_standings_rank"
  end
end
