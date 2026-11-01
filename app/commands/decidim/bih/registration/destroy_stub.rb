# frozen_string_literal: true

module Decidim
  module Bih
    module Registration
      # Throws away an unconfirmed registration: the way out for the citizen
      # who mistyped the number ("Počni ispočetka") and the day-7 deletion of
      # the lifecycle sweep, through ONE sequence so they can never diverge.
      #
      # Only ever allowed while the account holds nothing (PendingLifecycle
      # .stub?). The guard runs inside the row lock: a grant from a link tapped
      # a second ago must win over a delete that started a second earlier.
      #
      # Returns :destroyed, :refused (the locked re-check said no) or :gone
      # (the row disappeared under us — somebody else already did this).
      # Logs the id only: never the address, never the number.
      class DestroyStub
        def self.call(user) = new(user).call

        def initialize(user)
          @user = user
        end

        def call
          user_id = @user.id
          outcome = ActiveRecord::Base.transaction do
            @user.lock!
            next :refused unless PendingLifecycle.stub?(@user)

            Decidim::Bih::LoginToken.where(user: @user).destroy_all
            Decidim::Authorization.where(user: @user).destroy_all
            Decidim::Bih::CitizenProfile.where(decidim_user_id: @user.id).destroy_all
            # A referral link records the invitee with a plain foreign key and
            # no ON DELETE, so without this the destroy below is refused by
            # PostgreSQL. A pending row is all it can be here: a rewarded
            # referral needs a grant, which stub? has already refused.
            Decidim::Bih::Goodwill::Referral.where(invitee_id: @user.id).destroy_all
            destroy_empty_goodwill_account!
            @user.destroy!
            :destroyed
          end
          Rails.logger.info("[registracija] pending registration removed for user #{user_id}") if outcome == :destroyed
          outcome
        rescue ActiveRecord::RecordNotFound
          # The row went while we were reaching for it: the other caller won.
          :gone
        rescue ActiveRecord::InvalidForeignKey => e
          # Some row still points at this account. Refusing is the same answer
          # the locked re-check gives. The class only — never the address,
          # never the number.
          Rails.logger.warn("[registracija] pending registration removal refused for user #{user_id}: #{e.class}")
          :refused
        end

        private

        # An account row whose owner is gone is an orphan nothing can reach.
        # It can only ever be empty here (stub? refuses anything with points),
        # and postings are append-only, so a row with entries is left alone
        # and the user destroy is refused by the foreign key instead.
        def destroy_empty_goodwill_account!
          account = PendingLifecycle.goodwill_account_for(@user)
          return if account.blank? || account.entries.exists?

          account.destroy!
        end
      end
    end
  end
end
