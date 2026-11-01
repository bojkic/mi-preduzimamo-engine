# frozen_string_literal: true

class CascadePlatformReceiptDeletion < ActiveRecord::Migration[7.2]
  def up
    change_receipt_foreign_keys(:cascade)
  end

  def down
    change_receipt_foreign_keys(:restrict)
  end

  private

  def change_receipt_foreign_keys(action)
    [:decidim_users, :decidim_organizations].each do |table|
      remove_foreign_key :decidim_bih_platform_deliveries, table
      add_foreign_key :decidim_bih_platform_deliveries, table, on_delete: action
    end
  end
end
