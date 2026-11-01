# frozen_string_literal: true

class AddEffectPhaseToInboundDeliveries < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_viber_inbound_deliveries,
               :phase,
               :string,
               null: false,
               default: "handler"
    add_column :decidim_bih_viber_inbound_deliveries, :encrypted_effects, :text
    add_column :decidim_bih_viber_inbound_deliveries,
               :effects_cursor,
               :integer,
               null: false,
               default: 0
    add_column :decidim_bih_viber_inbound_deliveries,
               :effects_count,
               :integer,
               null: false,
               default: 0

    execute <<~SQL.squish
      UPDATE decidim_bih_viber_inbound_deliveries
      SET phase = 'complete'
      WHERE state = 'processed'
    SQL

    add_check_constraint :decidim_bih_viber_inbound_deliveries,
                         "phase IN ('handler', 'effects', 'complete')",
                         name: "chk_bih_inbound_delivery_phase"
    add_check_constraint :decidim_bih_viber_inbound_deliveries,
                         "effects_cursor >= 0 AND effects_count >= 0 AND effects_cursor <= effects_count",
                         name: "chk_bih_inbound_effect_cursor"
  end

  def down
    remove_check_constraint :decidim_bih_viber_inbound_deliveries,
                            name: "chk_bih_inbound_effect_cursor"
    remove_check_constraint :decidim_bih_viber_inbound_deliveries,
                            name: "chk_bih_inbound_delivery_phase"
    remove_column :decidim_bih_viber_inbound_deliveries, :effects_count
    remove_column :decidim_bih_viber_inbound_deliveries, :effects_cursor
    remove_column :decidim_bih_viber_inbound_deliveries, :encrypted_effects
    remove_column :decidim_bih_viber_inbound_deliveries, :phase
  end
end
