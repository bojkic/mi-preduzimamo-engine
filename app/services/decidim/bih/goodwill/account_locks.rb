# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # All wallet/admission mutations use account IDs, ascending for transfers.
      # Never lock issuance: it would serialize unrelated citizens.
      module AccountLocks
        module_function
        def lock!(*accounts)
          accounts.flatten.compact.reject { |a| a.kind == "system" }.uniq(&:id).sort_by(&:id).each do |account|
            AdvisoryLock.acquire!("goodwill-account:#{account.id}")
          end
        end
        def with(*accounts)
          Account.transaction do
            lock!(*accounts)
            yield
          end
        end
      end
    end
  end
end
