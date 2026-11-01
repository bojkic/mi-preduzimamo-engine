# frozen_string_literal: true

module Decidim
  module Bih
    # Base class for the chunked-fan-out bell jobs (one job per ≤CHUNK_SIZE
    # recipients). It owns the two pieces every fan-out job shares:
    #
    #   - the Sidekiq queue + deserialization-discard contract
    #   - the active-user re-filter applied at perform time (state can change
    #     between enqueue and run, so we re-check blocked/deleted/confirmed here)
    #
    # CHUNK_SIZE lives here so the "≤50 per job" slicing constant is defined ONCE
    # for both the enqueuing services and the consuming jobs.
    #
    # :events is Decidim's notification queue and IS listed in config/sidekiq.yml;
    # a :notifications queue would never be consumed by the running Sidekiq
    # process, so notifications would silently never deliver.
    #
    # Subclasses implement #perform, decode their own opts, and call
    # #each_eligible_user(organization, user_ids) to iterate the recipients.
    class ChunkedBellJob < Decidim::ApplicationJob
      # Recipients per enqueued job. The enqueuing service slices the resolved id
      # list with each_slice(CHUNK_SIZE); the job receives one slice as :user_ids.
      CHUNK_SIZE = 50

      queue_as :events

      discard_on ActiveJob::DeserializationError

      private

      # Yield each requested user that is still an active, confirmed, non-blocked
      # member of the organization. Re-filtered at perform time because user state
      # may have changed since the chunk was enqueued.
      def each_eligible_user(organization, user_ids, &)
        eligible_users(organization, user_ids).each(&)
      end

      def eligible_users(organization, user_ids)
        Decidim::User
          .where(organization:, id: user_ids)
          .where(blocked: false, deleted_at: nil)
          .where.not(confirmed_at: nil)
      end
    end
  end
end
