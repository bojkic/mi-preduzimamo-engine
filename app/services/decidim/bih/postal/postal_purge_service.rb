# frozen_string_literal: true

module Decidim
  module Bih
    module Postal
      # Purges PENDING (never-granted) postal_letter authorizations whose
      # +created_at+ is older than +cutoff+.
      #
      # What is deleted:
      #   - The Authorization row itself (which holds the mailing address in
      #     verification_metadata). Destroying the row is the purge of the address.
      #
      # What is NOT touched:
      #   - Granted (confirmed) postal_letter authorizations — those are kept and
      #     subject to the standard retention policy.
      #   - The Decidim::User account — never deleted by this job.
      #   - Any postal LoginTokens — those expire naturally within 30 days.
      #
      # Default cutoff: 6 months ago. Callers may supply a different cutoff for
      # testing or explicit operator overrides.
      #
      # Dry-run by default — pass +dry_run: false+ to apply.
      class PostalPurgeService
        Result = Struct.new(:dry_run, :purged_count, keyword_init: true)

        class << self
          def call(**)
            new(**).call
          end
        end

        def initialize(organization:, cutoff: 6.months.ago, dry_run: true)
          @organization = organization
          @cutoff = cutoff
          @dry_run = dry_run
        end

        def call
          scope = pending_postal_authorizations_before_cutoff
          count = scope.count

          scope.destroy_all unless @dry_run || count.zero?

          Result.new(dry_run: @dry_run, purged_count: count)
        end

        private

        # Pending = granted_at IS NULL (never confirmed). Organization-scoped so
        # multi-tenant deploys never bleed across orgs.
        def pending_postal_authorizations_before_cutoff
          Decidim::Authorization
            .where(name: "postal_letter")
            .where(granted_at: nil)
            .where(decidim_authorizations: { created_at: ...@cutoff })
            .joins(:user)
            .where(decidim_users: { decidim_organization_id: @organization.id })
        end
      end
    end
  end
end
