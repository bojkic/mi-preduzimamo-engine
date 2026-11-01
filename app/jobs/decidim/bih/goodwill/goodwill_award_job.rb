# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Awards goodwill points off the request cycle. Event subscribers enqueue
      # this so the user-facing action (commenting, publishing, liking) is never
      # slowed or broken by ledger writes. Idempotency makes retries safe.
      class GoodwillAwardJob < ActiveJob::Base
        queue_as :goodwill

        retry_on ActiveRecord::Deadlocked,
                 ActiveRecord::LockWaitTimeout,
                 wait: :polynomially_longer,
                 attempts: 5
        discard_on ActiveJob::DeserializationError, ActiveRecord::RecordNotFound

        # `owner` is a GlobalID-serialisable Decidim::User. `action` is a schedule
        # key (String/Symbol). `idempotency_key` dedupes the source event.
        def perform(owner:, action:, idempotency_key: nil, metadata: {})
          return if owner.blank?

          EarningRules.new.award(owner, action.to_sym, idempotency_key:, metadata: metadata || {})
        end
      end
    end
  end
end
