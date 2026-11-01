# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      class Reconciliation
        def self.run(organization, fix: false)
          new(organization, fix:).run
        end

        def initialize(organization, fix:)
          @organization, @fix = organization, fix
        end

        def run
          @drift = []
          if @fix
            accounts.find_each do |account|
              AccountLocks.with(account) do
                account.lock!
                inspect_account(account)
              end
            end
          else
            # A real read-only snapshot: no cache repair, audit record, account
            # creation or last-checked timestamp. Safe with PG read-only mode.
            Account.transaction(isolation: :repeatable_read) { accounts.find_each { |account| inspect_account(account) } }
          end
          @drift
        end

        private

        def accounts
          Account.where(organization: @organization)
        end

        def inspect_account(account)
          balance = account.recomputed_balance
          contribution = account.recomputed_contribution
          return if account.cached_balance == balance && account.cached_contribution == contribution

          @drift << { account_id: account.id, balance_before: account.cached_balance, balance_after: balance,
                      contribution_before: account.cached_contribution, contribution_after: contribution }
          return unless @fix

          account.update_columns(cached_balance: balance, cached_contribution: contribution) # rubocop:disable Rails/SkipsModelValidations
          ContributionProjection.after_commit(account) if account.kind == "user"
        end
      end
    end
  end
end
