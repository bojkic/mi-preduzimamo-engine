# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Shared Postgres transaction-level advisory lock used to serialise
      # concurrent goodwill writes. Both the per-account spend guard
      # (Ledger#lock_account!) and the per-owner award cap guard
      # (EarningRules#lock_owner!) acquire one of these so a balance/cap check
      # and the subsequent ledger write are atomic even under parallel jobs.
      #
      # The lock is taken with pg_advisory_xact_lock, which is automatically
      # released at the end of the surrounding DB transaction — callers MUST be
      # inside an ActiveRecord::Base.transaction (both call sites are).
      #
      # +key+ is a free-form String namespacing the lock; it is mapped to the
      # bigint the advisory-lock API needs via hashtext(). Caller-supplied keys
      # are quoted before interpolation, so passing user data is injection-safe.
      module AdvisoryLock
        module_function

        def acquire!(key)
          quoted = ActiveRecord::Base.connection.quote(key.to_s)
          ActiveRecord::Base.connection.execute(
            "SELECT pg_advisory_xact_lock(hashtext(#{quoted})::bigint)"
          )
        end
      end
    end
  end
end
