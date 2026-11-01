# frozen_string_literal: true

module Decidim
  module Bih
    # "Moj doprinos" — a citizen's own goodwill wallet & statement: level +
    # progress, contribution score, spendable balance, and a transaction history
    # (the spec's "auditable ledger", scoped to the owner's own entries).
    #
    # GET /biceriseno/moj-doprinos  (requires a signed-in user)
    class WalletController < Decidim::ApplicationController
      include Decidim::Bih::Concerns::CommunityHubData

      def show
        user = current_organization_user
        unless user
          # Consistent citizen sign-in gate: contextual flash + land on the
          # sign-in form (not the bare homepage), matching the Komšiluk gates.
          flash[:alert] = t(".login_required")
          destination = decidim_bih.wallet_path
          CitizenReturnPath.store(session, organization: current_organization, path: destination)
          return redirect_to(decidim.new_user_session_path(redirect_url: destination))
        end

        @tab = params[:tab].presence_in(%w(pregled nagrade podrzi pozovi kako)) || "pregled"
        @account = Decidim::Bih::Goodwill::Account.find_by(
          organization: current_organization,
          owner_type: user.class.base_class.name,
          owner_id: user.id
        )
        @contribution = @account&.contribution_score || 0
        @balance = @account&.balance || 0
        @level = Decidim::Bih::Goodwill::Levels.for(@contribution)
        @streak = Decidim::Bih::Goodwill::Streaks.weekly_for(@account)
        @season_started_at = Decidim::Bih::Goodwill::EarningRules.season_started_at(current_organization)
        @season_score =
          (Decidim::Bih::Goodwill::Streaks.season_score(@account, since: @season_started_at) if @season_started_at)
        @entries =
          if @account
            @account.entries.includes(:ledger_transaction).order(created_at: :desc, id: :desc).page(params[:page]).per(50)
          else
            Decidim::Bih::Goodwill::Entry.none
          end
        # Read-only monthly "contribution receipt": the citizen's OWN ledger
        # grouped by month with earned/spent/net subtotals and a running balance.
        @monthly_statement = Decidim::Bih::Goodwill::MonthlyStatement.new(@account).months
        @source_corrections = @account ? Decidim::Bih::Goodwill::CreditCorrection.where(account: @account).includes(:settlement, :original_transaction).order(id: :desc).page(params[:corrections_page]).per(20) : Decidim::Bih::Goodwill::CreditCorrection.none.page(1)
        report_ids = @source_corrections.filter_map do |correction|
          correction.source_key.delete_prefix("bih_report:") if correction.source_key.start_with?("bih_report:")
        end
        @correction_report_references = Decidim::Bih::Report.where(organization: current_organization,
          decidim_user_id: user.id, id: report_ids).pluck(:id, :reference).to_h
        @reward_fulfillments = Decidim::Bih::Goodwill::RewardFulfillment
                               .where(organization: current_organization, user: user)
                               .recent
                               .page(params[:rewards_page]).per(10)

        # Komšiluk profile-completion step (private — not exposed to other views).
        @citizen_profile = Decidim::Bih::CitizenProfile.find_by(
          decidim_organization_id: current_organization.id,
          decidim_user_id: user.id
        )
        load_community_tab(@tab) unless @tab == "pregled"
      end
    end
  end
end
