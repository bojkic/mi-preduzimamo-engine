# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      # The branded sticker and Milica gesture pack. Files are served by the
      # HOST app, so this module only builds absolute organization-scoped URLs.
      # Existing stickers are PNGs; persona gestures have an animated GIF for
      # the web UI and a provider-safe static JPEG for chat channels that reject
      # animated GIFs (notably Viber Bots).
      #
      # Usage:
      #   Decidim::Bih::Concierge::Stickers.url_for(:prijavljeno, organization: org)
      #   # => "https://host.example.org/mi/stickers/prijavljeno.png"
      module Stickers
        LEGACY_IDS = [:prijavljeno, :podrzano, :glas, :hvala, :preuzimamo, :rijeseno, :stize, :volim, :bravo].freeze
        PERSONA_IDS = [
          :milica_wave, :milica_tablet, :milica_map, :milica_heart,
          :milica_sleeves, :milica_thumbs_up
        ].freeze
        IDS = (LEGACY_IDS + PERSONA_IDS).freeze

        # Path prefix the host app serves the pack from.
        PATH_PREFIX = "/mi/stickers"

        module_function

        # Absolute https URL for a sticker, scoped to +organization+'s host.
        # Returns nil for an unknown id, so a typo can never send a 404 image
        # (the caller treats nil as "no sticker", keeping the send best-effort).
        def url_for(id, organization: nil, variant: :animated)
          key = id.to_sym
          return nil unless IDS.include?(key)

          "https://#{host_for(organization)}#{path_for(key, variant:)}"
        end

        def path_for(id, variant: :animated)
          key = id.to_sym
          return unless IDS.include?(key)
          return "#{PATH_PREFIX}/#{key}.png" if LEGACY_IDS.include?(key)

          extension = variant.to_sym == :static ? "jpg" : "gif"
          "/mi/milica/#{key.to_s.delete_prefix("milica_")}.#{extension}"
        end

        # The host to build sticker URLs against: the organization's host when
        # present, else the engine's neutral fallback (dev/test only — production
        # always has an org host). Host apps may override Decidim::Bih.default_host.
        def host_for(organization)
          host = organization.respond_to?(:host) ? organization.host : nil
          host.to_s.strip.empty? ? Decidim::Bih.default_host : host
        end
      end
    end
  end
end
