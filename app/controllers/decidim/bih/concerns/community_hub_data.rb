# frozen_string_literal: true

module Decidim
  module Bih
    module Concerns
      # Shared query logic used by CommunityHubController (the tab-based hub).
      # The legacy standalone controllers (LeaderboardController, RewardsController,
      # InviteController, KakoController) no longer have show actions and do NOT
      # include this concern; their routes are 301 redirects to the hub.
      #
      # Including controllers must expose +current_organization+ and optionally
      # +current_user+ (standard Decidim::ApplicationController).
      module CommunityHubData
        extend ActiveSupport::Concern

        # current_organization_user + wallet_balance_for live in the shared
        # Goodwill wallet concern (used by the wallet/rewards/gifts controllers
        # too); include it here rather than redefining them.
        include Decidim::Bih::GoodwillWallet

        def load_community_tab(tab)
          case tab
          when "tabla"
            @rows, @period, @citizen_of_the_month = leaderboard_data(params[:period])
          when "trka"
            @race_rows, @race_zone, @race_leaders, @race_viewer_row, @race_frozen, @race_computed_at =
              race_data(params[:zona])
            @race_config = Decidim::Bih::Race::Config.new(organization: current_organization)
            # The invite CTA under the citizen's own row quotes what a referral
            # pays. It comes from the schedule, never from a literal, so the page
            # and BODOVNIK can never disagree.
            @race_referral_points = Decidim::Bih::Goodwill::EarningRules.points_for_action(
              :referral, organization: current_organization
            )
          when "nagrade"
            @rewards, @balance, @launch_invitations_remaining = rewards_catalog_data
            @my_launch_invitation = current_organization_user && Decidim::Bih::Goodwill::RewardFulfillment.find_by(
              organization: current_organization,
              user: current_organization_user,
              reward_key: Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY,
              auto_issued: true
            )
          when "pozovi"
            # Capture an inbound ?ref= referral code into the session so
            # deep-link sharing still attributes the referral.
            Decidim::Bih::Goodwill::Referrals.capture_from_params(params, session)
            @links = invite_links_data(request.base_url)
          when "podrzi"
            @organizations = Decidim::Bih::PartnerProfile.goodwill_eligible.where(organization: current_organization).order(:display_name)
            @balance = wallet_balance_for(current_organization_user)
          when "kako"
            @schedule, @levels, @rewards, @daily_caps = kako_data
          end
        end

        # ---- leaderboard --------------------------------------------------- #

        # Returns [rows, period, citizen_of_the_month].
        # +period+ is one of LeaderboardController::PERIODS (default "all").
        def leaderboard_data(period_param)
          period = period_param.presence_in(Decidim::Bih::LeaderboardController::PERIODS) || "all"
          rows = rows_from_cache(cached_leaderboard(period, limit: Decidim::Bih::LeaderboardController::TOP_N * 2))
                 .first(Decidim::Bih::LeaderboardController::TOP_N)
          cotm = rows_from_cache(cached_leaderboard("month", limit: 5)).first
          [rows, period, cotm]
        end

        # ---- trka komšiluka ------------------------------------------------ #

        # Reads the CACHED standings only — never Scorer. Returns
        # [rows, zone, leaders, viewer_row, frozen, computed_at].
        # `leaders` is { "grad" => Standing|nil, "selo" => Standing|nil }; both
        # cards are always shown so a selo komšiluk sees its own league leader
        # rather than reading itself off the bottom of one long list.
        def race_data(zone_param)
          zone = zone_param.to_s.presence_in(Decidim::Bih::LocalArea::ZONES)
          standings = Decidim::Bih::Race::Standings.new(current_organization)

          @race_scores_visible = Decidim::Bih::Race::Visibility.visible?(current_organization)
          @race_closed = Decidim::Bih::Race::Config.new(organization: current_organization).finished?
          @race_winners = standings.final? ? Decidim::Bih::LocalArea::ZONES.index_with { |z| standings.leader(z)&.display_name } : {}
          unless @race_scores_visible
            return [[], zone, Decidim::Bih::LocalArea::ZONES.index_with { nil }, nil, standings.final?, standings.computed_at]
          end
          rows = standings.rows(zone:)
          leaders = Decidim::Bih::LocalArea::ZONES.index_with { |z| standings.leader(z) }
          viewer_row = race_viewer_row(standings)

          [rows, zone, leaders, viewer_row, standings.final?, standings.computed_at]
        end

        # ---- rewards ------------------------------------------------------- #

        def rewards_catalog_data
          # Prag-nagrade (auto_issue_at_threshold) imaju svoju posebnu karticu
          # (javni brojač + "moja pozivnica") i NIKAD se ne nude za ručno
          # preuzimanje ovdje.
          rewards = Decidim::Bih::Goodwill::RewardsCatalog.manually_redeemable(current_organization)
          balance = wallet_balance_for(current_organization_user)

          # Agregat, nikad identiteti — javni brojač preostalih pozivnica u
          # tekućem talasu. Keširano jer visi na svakom prikazu nagrada.
          invitation_reward = Decidim::Bih::Goodwill::LaunchInvitation.reward_for(current_organization)
          remaining = if invitation_reward && !invitation_reward.expired?
            Rails.cache.fetch(
            "goodwill:launch-invitation:remaining:#{current_organization.id}",
            expires_in: 60.seconds
            ) { Decidim::Bih::Goodwill::LaunchInvitation.remaining(current_organization) }
          end

          [rewards, balance, remaining]
        end

        # ---- invite -------------------------------------------------------- #

        def invite_links_data(base_url)
          user = current_organization_user
          Decidim::Bih::Goodwill::InviteLinks.new(user, base_url:) if user
        end

        # ---- kako ---------------------------------------------------------- #

        def kako_data
          schedule, caps = begin
            rules = Decidim::Bih::Goodwill::EarningRules.new(organization: current_organization)
            @earning_rules = rules
            @cap_periods = rules.public_schedule.keys.index_with { |action| rules.cap_period_for(action) }
            [rules.public_schedule, rules.public_schedule.keys.index_with { |action| rules.cap_for(action) }.compact]
          rescue StandardError
            @earning_rules = Decidim::Bih::Goodwill::EarningRules.new
            @cap_periods = @earning_rules.public_schedule.keys.index_with { |action| @earning_rules.cap_period_for(action) }
            fallback = @earning_rules.public_schedule
            inactive = Decidim::Bih.volunteer_work_award_unit.to_sym == :day ? :volunteer_hour : :volunteer_day
            [fallback.except(inactive), {}]
          end
          levels = Decidim::Bih::Goodwill::Levels::TABLE
          # Isti razlog kao u rewards_catalog_data: prag-nagrada nije nešto na
          # šta se bodovi "troše", pa se ne navodi u SPEND listi objašnjenja.
          rewards = Decidim::Bih::Goodwill::RewardsCatalog.manually_redeemable(current_organization)
          [schedule, levels, rewards, caps]
        end

        private

        # The signed-in citizen's own komšiluk, so it can be highlighted even when
        # it is nowhere near the top 15.
        def race_viewer_row(standings)
          user = current_organization_user
          return nil unless user

          profile = Decidim::Bih::CitizenProfile.find_by(
            organization: current_organization, decidim_user_id: user.id
          )
          return nil if profile&.komsiluk_id.blank?

          edition = Decidim::Bih::Race::Edition.for(current_organization)
          member = edition&.memberships&.find_by(decidim_user_id: user.id)
          standings.for_komsiluk(member&.komsiluk_id || profile.komsiluk_id)
        end

        # ---- leaderboard cache helpers (mirrors LeaderboardController) ----- #

        def cached_leaderboard(period, limit:)
          Rails.cache.fetch(leaderboard_cache_key(period, limit:),
                            expires_in: Decidim::Bih::LeaderboardController::CACHE_TTL) do
            leaderboard_for_period(period, limit:).map { |account| [account.id, score_for_hub(account)] }
          end
        end

        def leaderboard_for_period(period, limit:)
          case period
          when "month"
            Decidim::Bih::Goodwill::Account.contribution_leaderboard_since(
              current_organization, since: Time.current.beginning_of_month, limit:
            )
          when "week"
            Decidim::Bih::Goodwill::Account.contribution_leaderboard_since(
              current_organization, since: Time.current.beginning_of_week, limit:
            )
          else
            Decidim::Bih::Goodwill::Account.contribution_leaderboard(current_organization, limit:)
          end
        end

        def rows_from_cache(cached_rows)
          account_ids = cached_rows.map(&:first)
          accounts_by_id = Decidim::Bih::Goodwill::Account
                           .public_leaderboard_accounts
                           .where(organization: current_organization, id: account_ids)
                           .includes(:owner)
                           .index_by(&:id)

          cached_rows.filter_map do |account_id, score|
            account = accounts_by_id[account_id]
            next unless account

            user = account.owner
            next if user.nil? || !user.respond_to?(:nickname) || user.blocked? || user.deleted?
            next if Decidim::Bih::Goodwill::Account.excluded_from_public_leaderboard?(user)

            {
              user:,
              score:,
              level: Decidim::Bih::Goodwill::Levels.for(account.contribution_score),
              operator: Decidim::Bih::OperatorAuthorization.operator?(user, organization: current_organization)
            }
          end
        end

        def score_for_hub(account)
          if account.attributes.has_key?("windowed_score")
            account.attributes["windowed_score"].to_i
          else
            account.contribution_score
          end
        end

        def leaderboard_cache_key(period, limit:)
          scope = Decidim::Bih::Goodwill::Transaction.where(organization: current_organization)
          corrections = Decidim::Bih::Goodwill::CreditCorrection.where(organization: current_organization)
          since = period_start_for(period)
          [
            "decidim_bih", "leaderboard", current_organization.id, period, limit,
            since&.to_date&.iso8601, scope.count, scope.maximum(:id),
            corrections.count, corrections.maximum(:id),
            Decidim::Bih::PublicRecognition.cohort_version(current_organization)
          ].compact.join("/")
        end

        def period_start_for(period)
          case period
          when "month" then Time.current.beginning_of_month
          when "week" then Time.current.beginning_of_week
          end
        end
      end
    end
  end
end
