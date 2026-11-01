# frozen_string_literal: true

class RenameInboundLinkAssociation < ActiveRecord::Migration[7.2]
  def change
    rename_column :decidim_bih_inbound_email_links, :association, :matching_method
  end
end
