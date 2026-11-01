# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Weekly engagement streaks and per-season scoring, computed-on-read from
      # the immutable ledger. Presentation-only (mirrors Levels): it reads earn
      # history and never writes, so there is no cached column to drift.
      #
      #   * weekly_for(account) — the citizen's CURRENT weekly streak: the number
      #     of consecutive ISO weeks, ending at this week (or last week if they
      #     haven't earned yet this week), in which they earned at least once.
      #   * season_score(account, since:) — goodwill points EARNED since +since+,
      #     reusing the same earn-credit aggregation the leaderboard windows use.
      module Streaks
        module_function

        # The trailing run of consecutive ISO weeks with >=1 earn for +account+.
        # 0 when there is no current streak (no earn this week AND none last week).
        # A streak stays "alive" through the current week even before earning in
        # it: we anchor the walk at last week if this week is still empty, so a
        # user who earned last week but not yet this week shows their streak
        # rather than dropping to 0 mid-week.
        def weekly_for(account)
          return 0 if account.nil?

          weeks = earn_week_starts(account)
          return 0 if weeks.empty?

          this_week = Time.current.in_time_zone("Europe/Sarajevo").to_date.beginning_of_week
          last_week = this_week - 7

          # Anchor: if they earned this week, count from this week; else if they
          # earned last week, count from last week; otherwise the streak is broken.
          cursor =
            if weeks.include?(this_week)
              this_week
            elsif weeks.include?(last_week)
              last_week
            else
              return 0
            end

          present = weeks.to_set
          streak = 0
          while present.include?(cursor)
            streak += 1
            cursor -= 7
          end
          streak
        end

        # Points earned by +account+ since +since+ (a Date/Time). 0 when +since+
        # is nil (no season configured) or the account is nil. Live aggregation
        # over the immutable ledger's earn credits — no cached column.
        def season_score(account, since:)
          return 0 unless since
          ContributionProjection.score(account, since:)
        end

        # The distinct Monday (ISO week start) dates on which +account+ earned.
        # A single indexed query returning a handful of dates at this scale.
        #
        # created_at is stored as a naive UTC timestamp, but the streak walk in
        # #weekly_for compares against Date.current.beginning_of_week (the app's
        # Europe/Sarajevo zone). Bucket by LOCAL week — converting the UTC instant
        # to the app zone first — so an earn made in the first hours of a local
        # Monday isn't filed under the previous (UTC) week and read as a gap.
        def earn_week_starts(account)
          ContributionProjection.active_weeks(account)
        end
      end
    end
  end
end
