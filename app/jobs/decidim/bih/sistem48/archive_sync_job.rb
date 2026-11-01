# frozen_string_literal: true

module Decidim
  module Bih
    module Sistem48
      # Thin async wrapper around ArchiveSync so the city-status mirror can be
      # scheduled off the request cycle (cron enqueues, or the rake task calls
      # the service directly). All error handling lives in the service, which is
      # fully rescued; the job just resolves the organization and delegates.
      class ArchiveSyncJob < Decidim::ApplicationJob
        # :integrations isolates external-site work (cf. the Odoo refresh job)
        # from request follow-ups; it is consumed by the running Sidekiq process
        # (see config/sidekiq.yml). This is a low-frequency maintenance job.
        queue_as :integrations

        discard_on ActiveJob::DeserializationError

        def perform(organization_id)
          organization = Decidim::Organization.find_by(id: organization_id)
          return unless organization

          ArchiveSync.new(organization).call
        end
      end
    end
  end
end
