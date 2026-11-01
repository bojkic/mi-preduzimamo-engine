# frozen_string_literal: true

module Decidim
  module Bih
    module Race
      # The rules of the neighbourhood race, in one place.
      #
      # Three layers, exactly like Goodwill::EarningRules:
      #   DEFAULTS → host config (Decidim::Bih.race_*) → per-org Decidim::Bih::Setting.
      #
      # Everything is time-zone explicit. "6.9. u 00:00" and "14.10. u 20:00" are
      # published rules; a UTC off-by-two would silently count or drop a whole
      # evening of activity.
      class Config
        TIME_ZONE = "Europe/Sarajevo"
        DEFAULT_WINDOW_FROM = "2026-09-06 00:00:00"
        DEFAULT_WINDOW_TO = "2026-10-14 20:00:00"
        DEFAULT_WEIGHTS = { registered: 1, report: 2, proposal: 3 }.freeze
        # Per person, per komšiluk score. Anything above still earns the citizen
        # personal points — it just stops adding to the neighbourhood's total, so
        # the score measures HOW MANY PEOPLE took part, not how tireless one was.
        DEFAULT_CAPS = { report: 5, proposal: 3 }.freeze
        NAMESPACE = "race"

        def initialize(organization: nil)
          @organization = organization
        end

        def zone
          @zone ||= ActiveSupport::TimeZone[TIME_ZONE]
        end

        def window_from
          @window_from ||= parse(setting("window_from") || Decidim::Bih.race_window_from || DEFAULT_WINDOW_FROM)
        end

        def window_to
          @window_to ||= parse(setting("window_to") || Decidim::Bih.race_window_to || DEFAULT_WINDOW_TO).tap do |value|
            raise ArgumentError, "race window must end after start" unless value > window_from
          end
        end

        def weights
          @weights ||= DEFAULT_WEIGHTS.merge(symbolize(Decidim::Bih.race_weights)).merge(symbolize(setting("weights")))
        end

        def caps
          @caps ||= DEFAULT_CAPS.merge(symbolize(Decidim::Bih.race_caps)).merge(symbolize(setting("caps")))
        end

        # Half-open interval [from, to): 14.10. at exactly 20:00 is already out,
        # which is what "zaključava se u 20:00" means.
        def open?(at = Time.current)
          at >= window_from && at < window_to
        end

        def finished?(at = Time.current)
          at >= window_to
        end

        private

        attr_reader :organization

        def settings
          @settings ||= Decidim::Bih::Setting.namespace_for(organization, NAMESPACE)
        rescue StandardError
          {}
        end

        def setting(key)
          settings[key].presence
        end

        def parse(value)
          return value if value.respond_to?(:strftime) && value.respond_to?(:zone)

          zone.parse(value.to_s)
        end

        def symbolize(hash)
          return {} unless hash.is_a?(Hash)

          hash.each_with_object({}) do |(k, v), memo|
            next if v.nil? || v.to_s.strip.empty?

            int_value = Integer(v, exception: false)
            raise ArgumentError, "invalid race integer" unless int_value && int_value.between?(0, 10_000)
            raise ArgumentError, "unknown race key" unless (DEFAULT_WEIGHTS.keys + DEFAULT_CAPS.keys).include?(k.to_sym)
            memo[k.to_sym] = int_value
          end
        end
      end
    end
  end
end
