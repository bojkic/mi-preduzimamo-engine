# frozen_string_literal: true

module Decidim
  module Bih
    # Inline SVG icon set for the MI bot showcase page. Decidim's CSP blocks
    # external icon CDNs (the design kit prototyped with Lucide over unpkg), so
    # the page ships its own compact set of Lucide-style outline glyphs (2px
    # stroke, round caps/joins) rendered inline as `currentColor`. Sizing and
    # colour are controlled by the caller (CSS / `style`), keeping the markup
    # crisp at any scale.
    module MiBotIconsHelper
      # Lucide-style outline path bodies, viewBox 0 0 24 24, currentColor stroke.
      # Single-line SVG path data is intentionally not wrapped (it is opaque
      # geometry, not prose), so line-length is disabled for the literal block.
      # rubocop:disable Layout/LineLength
      MI_BOT_ICON_PATHS = {
        # --- phone chrome ---
        "chevron-left" => '<path d="m15 18-6-6 6-6"/>',
        "send" => '<path d="m22 2-7 20-4-9-9-4Z"/><path d="M22 2 11 13"/>',
        "phone" => '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72c.13.96.36 1.9.7 2.81a2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45c.91.34 1.85.57 2.81.7A2 2 0 0 1 22 16.92Z"/>',
        "video" => '<path d="m22 8-6 4 6 4V8Z"/><rect width="14" height="12" x="2" y="6" rx="2" ry="2"/>',
        "info" => '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/>',
        "more-vertical" => '<circle cx="12" cy="12" r="1"/><circle cx="12" cy="5" r="1"/><circle cx="12" cy="19" r="1"/>',
        "badge-check" => '<path d="M3.85 8.62a4 4 0 0 1 4.78-4.77 4 4 0 0 1 6.74 0 4 4 0 0 1 4.78 4.78 4 4 0 0 1 0 6.74 4 4 0 0 1-4.77 4.78 4 4 0 0 1-6.75 0 4 4 0 0 1-4.78-4.77 4 4 0 0 1 0-6.76Z"/><path d="m9 12 2 2 4-4"/>',
        "signal" => '<path d="M2 20h.01"/><path d="M7 20v-4"/><path d="M12 20v-8"/><path d="M17 20V8"/><path d="M22 4v16"/>',
        "wifi" => '<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>',
        "battery-full" => '<rect width="16" height="10" x="2" y="7" rx="2" ry="2"/><line x1="22" x2="22" y1="11" y2="13"/><line x1="6" x2="6" y1="11" y2="13"/><line x1="10" x2="10" y1="11" y2="13"/><line x1="14" x2="14" y1="11" y2="13"/>',
        # --- card glyphs ---
        "construction" => '<rect x="2" y="6" width="20" height="8" rx="1"/><path d="M17 14v7"/><path d="M7 14v7"/><path d="M17 3v3"/><path d="M7 3v3"/><path d="M10 14 2.3 6.3"/><path d="m14 6 7.7 7.7"/><path d="m8 6 8 8"/>',
        "check" => '<path d="M20 6 9 17l-5-5"/>',
        "bell" => '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
        # --- icon set ---
        "megaphone" => '<path d="m3 11 18-5v12L3 14v-3z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>',
        "wallet" => '<path d="M19 7V4a1 1 0 0 0-1-1H5a2 2 0 0 0 0 4h15a1 1 0 0 1 1 1v4h-3a2 2 0 0 0 0 4h3a1 1 0 0 0 1-1v-2a1 1 0 0 0-1-1"/><path d="M3 5v14a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-4"/>',
        "map-pin" => '<path d="M20 10c0 4.993-5.539 10.193-7.399 11.799a1 1 0 0 1-1.202 0C9.539 20.193 4 14.993 4 10a8 8 0 0 1 16 0"/><circle cx="12" cy="10" r="3"/>',
        "sprout" => '<path d="M7 20h10"/><path d="M10 20c5.5-2.5.8-6.4 3-10"/><path d="M9.5 9.4c1.1.8 1.8 2.2 2.3 3.7-2 .4-3.5.4-4.8-.3-1.2-.6-2.3-1.9-3-4.2 2.8-.5 4.4 0 5.5.8z"/><path d="M14.1 6a7 7 0 0 0-1.1 4c1.9-.1 3.3-.6 4.3-1.4 1-1 1.6-2.3 1.7-4.6-2.7.1-4 1-4.9 2z"/>',
        "heart" => '<path d="M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z"/>',
        "vote" => '<path d="m9 12 2 2 4-4"/><path d="M5 7c0-1.1.9-2 2-2h10a2 2 0 0 1 2 2v12H5V7Z"/><path d="M22 19H2"/>',
        "message-circle" => '<path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/>',
        "check-check" => '<path d="M18 6 7 17l-5-5"/><path d="m22 10-7.5 7.5L13 16"/>',
        "clock" => '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
        "camera" => '<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3z"/><circle cx="12" cy="13" r="3"/>',
        "landmark" => '<line x1="3" x2="21" y1="22" y2="22"/><line x1="6" x2="6" y1="18" y2="11"/><line x1="10" x2="10" y1="18" y2="11"/><line x1="14" x2="14" y1="18" y2="11"/><line x1="18" x2="18" y1="18" y2="11"/><polygon points="12 2 20 7 4 7"/>'
      }.freeze
      # rubocop:enable Layout/LineLength

      # Render an inline SVG glyph. `size` and `stroke` are numeric; `color`
      # defaults to currentColor so the caller's text colour cascades. Output is
      # html_safe (the path data is a frozen constant, never user input).
      def mi_bot_icon(name, size: 20, stroke: 2, color: nil, css_class: nil)
        body = MI_BOT_ICON_PATHS[name.to_s]
        return "".html_safe unless body

        style = color ? "color:#{color};" : nil
        attrs = {
          xmlns: "http://www.w3.org/2000/svg", width: size, height: size,
          viewBox: "0 0 24 24", fill: "none", stroke: "currentColor",
          "stroke-width": stroke, "stroke-linecap": "round", "stroke-linejoin": "round",
          class: ["mi-bot-ico", css_class].compact.join(" "), style:, "aria-hidden": "true"
        }.compact
        tag.svg(body.html_safe, **attrs)
      end
    end
  end
end
