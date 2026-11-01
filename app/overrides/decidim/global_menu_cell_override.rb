# frozen_string_literal: true

# Override of Decidim core's global menu content block cell
# (Decidim::ContentBlocks::GlobalMenuCell).
#
# Problem: the global menu content block renders a static `id="home__menu"`. When
# the block appears more than once on the homepage (it can be placed twice in the
# homepage content-block layout), the same id is emitted multiple times — a
# duplicate id, which is a WCAG 4.1.1 ("Parsing") failure flagged by the audit.
#
# Two things have to change together to fix this cleanly:
#   1. The cell caches its rendered `show` keyed only on the organization +
#      locale (`cache_hash`), so a second render on the same page replays the
#      first render's cached HTML verbatim — including its id. Varying the cache
#      key per render makes the second render a cache miss so the template runs
#      again (and the two cached fragments stay distinct).
#   2. The template uses the computed, per-render id (see the matching
#      app/cells/.../global_menu/show.erb override).
#
# `home_menu_section_id` keeps the FIRST rendered instance on the literal
# `home__menu` id (so the host theme's `#home__menu.home__menu` rule keeps
# styling it) and suffixes any further instances within the same request, so
# every emitted id is unique while the `home__menu` CSS class is kept on all of
# them.
module Decidim
  module Bih
    module GlobalMenuCellOverride
      # Memoized per cell instance so cache_hash and the template agree on the id
      # for a given render, but each distinct cell render gets its own index.
      def home_menu_section_id
        @home_menu_section_id ||= begin
          index = controller.instance_variable_get(:@decidim_bih_home_menu_index).to_i
          controller.instance_variable_set(:@decidim_bih_home_menu_index, index + 1)
          index.zero? ? "home__menu" : "home__menu--#{index + 1}"
        end
      end

      private

      def cache_hash
        # NB: do NOT call `super` here. In the production (eager-loaded) engine
        # load path, `super` resolves back into this same method and recurses
        # (SystemStackError on every homepage render). Rebuild core
        # GlobalMenuCell#cache_hash's key inline and vary it per render so the
        # second placement is a cache miss (keeping each emitted id unique).
        [
          "decidim/content_blocks/global_menu",
          current_organization.cache_key_with_version,
          I18n.locale,
          home_menu_section_id
        ].join(Decidim.cache_key_separator)
      end
    end
  end
end

Decidim::ContentBlocks::GlobalMenuCell.prepend(Decidim::Bih::GlobalMenuCellOverride)
