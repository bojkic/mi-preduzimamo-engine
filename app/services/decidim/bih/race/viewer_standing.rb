# frozen_string_literal: true

module Decidim
  module Bih
    module Race
      # The signed-in citizen's OWN komšiluk standing, cheap enough to ask for on
      # every page render.
      #
      # The community hub asks the same question directly (see
      # CommunityHubData#race_viewer_row) and is deliberately left alone: that
      # page is where the numbers are read carefully, so it keeps an uncached,
      # authoritative ActiveRecord row. This class exists for the opposite case
      # — the site-wide invite nudge, which appears on every page and must cost
      # almost nothing and must never be the reason a page fails to render.
      #
      # So: a small value object rather than an AR row (safe to cache), a
      # sentinel for "no standing" so absence is cached too, and a rescue that
      # turns any failure into a missing nudge instead of a 500.
      class ViewerStanding
        Summary = Struct.new(:komsiluk_id, :display_name, :zona, :rank_overall, :rank_in_zone,
                             :score, :registered, keyword_init: true)

        # Standings refresh at most once per 10 minutes (RefreshStandingsJob), so
        # five is comfortably inside one refresh cycle: the nudge can lag the
        # leaderboard by a few minutes, never by a stale rank nobody recognises.
        CACHE_TTL = 300

        # Cached in place of nil, because Rails.cache.fetch treating a nil block
        # result as a value is a subtlety this class should not depend on.
        MISSING = :none

        def self.summary(user, organization:)
          new(user, organization:).summary
        end

        def initialize(user, organization:)
          @user = user
          @organization = organization
        end

        def summary
          return nil if user.blank? || organization.blank?
          return nil unless Visibility.visible?(organization)

          value = cached { build_summary || MISSING }
          value == MISSING ? nil : value
        rescue StandardError => e
          report(e)
          nil
        end

        private

        attr_reader :user, :organization

        def build_summary
          komsiluk = komsiluk_id
          return nil if komsiluk.blank?

          row = standing_for(komsiluk)
          return nil unless row

          Summary.new(
            komsiluk_id: row.komsiluk_id,
            display_name: row.display_name,
            zona: row.zona,
            rank_overall: row.rank_overall,
            rank_in_zone: row.rank_in_zone,
            score: row.score,
            registered: row.registered
          )
        end

        def komsiluk_id
          member = Edition.for(organization)&.memberships&.find_by(decidim_user_id: user.id)
          return member.komsiluk_id if member
          Decidim::Bih::CitizenProfile.find_by(
            organization:, decidim_user_id: user.id
          )&.komsiluk_id
        end

        def standing_for(komsiluk_id)
          Decidim::Bih::Race::Standings.new(organization).for_komsiluk(komsiluk_id)
        end

        def cached(&block)
          store = defined?(::Rails) && ::Rails.respond_to?(:cache) ? ::Rails.cache : nil
          return block.call unless store

          store.fetch(cache_key, expires_in: CACHE_TTL, &block)
        end

        # The locale belongs in the key because the cached value contains one:
        # Standing#display_name goes through LocalArea#translated_name, which
        # transliterates the komšiluk name into the ACTIVE locale's script. A
        # locale-free key would let whichever locale a citizen happened to load
        # first win for the next five minutes, so a Cyrillic reader could get a
        # Cyrillic sentence wrapped around a Latin komšiluk name.
        def cache_key
          "bih:race:viewer-standing:#{organization.id}:#{user.id}:#{I18n.locale}:#{Visibility.version(organization)}"
        end

        def report(error)
          return unless defined?(::Rails) && ::Rails.respond_to?(:logger) && ::Rails.logger

          ::Rails.logger.warn("[decidim_bih] race viewer standing unavailable: #{error.class}")
        end
      end
    end
  end
end
