# frozen_string_literal: true

class AddSimpleScheduleToVolunteering < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_volunteer_availabilities, :day_keys, :jsonb, null: false, default: []
    add_column :decidim_bih_volunteer_availabilities, :month_keys, :jsonb, null: false, default: []
    add_column :decidim_bih_volunteer_availabilities, :time_slot_keys, :jsonb, null: false, default: []

    add_column :decidim_bih_volunteer_opportunities, :day_keys, :jsonb, null: false, default: []
    add_column :decidim_bih_volunteer_opportunities, :month_keys, :jsonb, null: false, default: []
    add_column :decidim_bih_volunteer_opportunities, :time_slot_keys, :jsonb, null: false, default: []
  end
end
