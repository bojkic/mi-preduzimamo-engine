# frozen_string_literal: true

# Compatibility for the existing homepage menu removed by Decidim0.32.
# Derived from Decidim0.31.7 under AGPL; provenance is retained in
# lib/decidim/bih/licenses/decidim-global-menu-NOTICE.txt.

require "decidim/bih/locale_path"

module Decidim
  module ContentBlocks
    class GlobalMenuCell < Decidim::ViewModel
      include Decidim::MenuHelper

      private

      def menu_item_path(item)
        Decidim::Bih::LocalePath.strip(item.url.to_s.split(/[?#]/, 2).first)
      end

      def menu_items
        @menu_items ||= home_content_block_menu.items
      end

      def method_missing(method_name, *_args)
        return super if (engine = engine(method_name)).blank?

        engine.routes.url_helpers
      end

      def respond_to_missing?(method_name, include_private = false)
        method_name.starts_with?("decidim_") || super
      end

      def engine(method_name)
        return if (manifest = Decidim.find_participatory_space_manifest(method_name.to_s.gsub(/\Adecidim_/, ""))).blank?

        manifest.context(:public).engine
      end

      def cache_hash
        ["decidim/content_blocks/global_menu", current_organization.cache_key_with_version, I18n.locale].join(Decidim.cache_key_separator)
      end
    end
  end
end
