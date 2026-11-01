# frozen_string_literal: true

module Decidim
  module Bih
    # "/dobrodosli" — the single page between a finished phone verification and
    # the rest of the platform. It answers three questions in one screen: the
    # account is confirmed, here is what you already earned, here are the three
    # things worth doing first.
    #
    # Read/write split (deliberate, see Onboarding::Welcome):
    #   GET  #show  renders and writes NOTHING. Onboarding::NextStep sends every
    #               freshly verified citizen here from a GET-time redirect, so a
    #               GET that stamped mi_welcomed_at would let a prefetch, a
    #               reload or a bot consume the one welcome the citizen gets.
    #   POST #start is the only writer: "Krenimo" stamps and moves on.
    #
    # The page is reached with the PWA marker (?app=1) appended by
    # CompletesPhoneAuthentication after a verify. Nothing here reads or strips
    # it — public/mi/mi-install.js does, in the host layout.
    class WelcomeController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      before_action :require_citizen!

      def show
        destination = next_step_path
        # "Nalog je potvrđen" is a lie to anyone who has not finished the chain,
        # so both actions ask the same question: is this citizen actually on the
        # welcome step? A citizen who typed the URL early is sent to the step
        # they are really on instead of being congratulated.
        return redirect_to(destination) unless welcome_step?(destination)

        load_points
      end

      def start
        destination = next_step_path

        # NextStep answers "dobrodosli" for exactly the citizens who are on this
        # step. Asking it, rather than re-deriving the conditions here, keeps a
        # single definition of the step and means a citizen who typed the URL
        # early is moved along WITHOUT burning their welcome.
        if welcome_step?(destination)
          Decidim::Bih::Onboarding::Welcome.mark!(@user)
          destination = next_step_path
        end

        redirect_to destination
      end

      private

      def require_citizen!
        @user = current_organization_user
        return true if @user

        flash[:alert] = t("decidim.bih.welcome.login_required")
        redirect_to(decidim.new_user_session_path)
        false
      end

      # Read-only: find_by, never Ledger#account_for, which is a
      # find_or_create_by! and would insert a wallet row for every visitor.
      # Same lookup as CommunityHubController#load_viewer_summary.
      #
      # The registration awards (verification + komsiluk_selected) are posted by
      # a low-priority background job that regularly finishes AFTER this page
      # has rendered; on 2026-09-07 a citizen saw "0 bodova" with 20 landing
      # seven seconds later. The page therefore shows at least what registration
      # is known to have earned — the same schedule the job pays from — and the
      # ledger catches up. Presentation only: nothing is written here.
      def load_points
        account = Decidim::Bih::Goodwill::Account.find_by(
          organization: current_organization,
          owner_type: @user.class.base_class.name,
          owner_id: @user.id
        )

        @registration_points = registration_points
        earned = @registration_points.values.sum
        @points = [account&.balance || 0, earned].max
        # "How much is still missing" is measured against the contribution
        # score, because that is what actually issues the invitation. The wallet
        # balance shown above it can be lower after a gift or a redemption; for
        # a citizen who has just verified the two are the same number.
        score = [account&.contribution_score || 0, earned].max
        reward = Decidim::Bih::Goodwill::LaunchInvitation.reward_for(current_organization)
        @invitation_available = reward.present? && !reward.expired?
        @missing = [reward.cost.to_i - score, 0].max if @invitation_available
      end

      # {verification: 10, komsiluk_selected: 10} for a citizen on the welcome
      # step (verified phone, komšiluk assigned). The komšiluk half is paid only
      # for a komšiluk the citizen chose — a postally assigned one never pays
      # (authorization_referral_override.rb#award_komsiluk_selected_if_verified).
      def registration_points
        rules = Decidim::Bih::Goodwill::EarningRules.new(organization: current_organization)
        points = { verification: rules.points_for(:verification) }
        profile = Decidim::Bih::CitizenProfile.find_by(
          decidim_organization_id: current_organization.id,
          decidim_user_id: @user.id
        )
        chosen = profile&.assigned? && profile.source != "postal"
        points[:komsiluk_selected] = rules.points_for(:komsiluk_selected) if chosen
        points.select { |_action, amount| amount.positive? }
      end

      # Same gate as CompletesPhoneAuthentication#phone_first_onboarding_chain?:
      # a host that has not switched phone-first on registers no :sms workflow,
      # so NextStep's phone form would be a 404 there.
      def next_step_path
        return "#{Decidim::Bih.public_path("moj-nalog")}?setup=1" unless Decidim::Bih.phone_first_registration

        Decidim::Bih::Onboarding::NextStep.for(@user, organization: current_organization)
      end

      def welcome_step?(destination)
        destination == Decidim::Bih.public_path("dobrodosli")
      end
    end
  end
end
