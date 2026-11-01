# frozen_string_literal: true

class AddAreaScopeToDecidimBihOperatorRoles < ActiveRecord::Migration[7.2]
  def change
    add_column :decidim_bih_operator_roles, :area_scope, :string, null: false, default: "all"
    add_column :decidim_bih_operator_roles, :komsiluk_ids, :jsonb, null: false, default: []
  end
end
