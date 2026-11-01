# frozen_string_literal: true

base_path = File.expand_path("..", __dir__)

Decidim::Shakapacker.register_path("#{base_path}/app/packs")
Decidim::Shakapacker.register_entrypoints(
  decidim_bih_admin: "#{base_path}/app/packs/entrypoints/decidim_bih_admin.js"
)
Decidim::Shakapacker.register_stylesheet_import(
  "stylesheets/decidim/bih/admin",
  group: :app
)
