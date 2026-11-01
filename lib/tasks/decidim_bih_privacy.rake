# frozen_string_literal: true

namespace :decidim_bih do
  namespace :privacy do
    desc "Run a privacy retention sweep for one organization (dry-run unless APPLY=1)"
    task retention_sweep: :environment do
      organization = find_retention_organization
      abort "Set ORGANIZATION_ID or HOST" unless organization

      # Cutoffs are derived from the privacy audit contracts, so a new bucket
      # becomes settable here the moment it is registered — no line to forget.
      cutoffs = Decidim::Bih::PrivacyAuditContracts.sweep_env_cutoffs.filter_map do |env_key, attribute|
        value = ENV.fetch(env_key, nil)
        [attribute, value] if value.present?
      end.to_h

      attributes = cutoffs.merge(
        organization: organization,
        report_coordinate_precision: ENV.fetch("REPORT_COORDINATE_PRECISION", nil),
        record_run: true,
        run_source: "rake"
      )
      result = if ENV["APPLY"] == "1"
                 Decidim::Bih::Privacy::RetentionSweep.authorized_live_call(**attributes)
               else
                 Decidim::Bih::Privacy::RetentionSweep.call(**attributes, dry_run: true)
               end

      puts "organization=#{organization.id} host=#{organization.host}"
      puts "dry_run=#{result.dry_run} apply=#{ENV["APPLY"] == "1"} total=#{result.total}"
      puts "retention_scope_key=#{Decidim::Bih::Privacy::RetentionSweep.scope_key(**attributes)}"
      puts "retention_run_id=#{result.run&.id}" if result.run
      result.counts.each { |key, count| puts "#{key}=#{count}" }
      puts "No changes were made. Set APPLY=1 to run with the same cutoffs." if result.dry_run
    end
  end
end

def find_retention_organization
  if ENV["ORGANIZATION_ID"].present?
    Decidim::Organization.find_by(id: ENV["ORGANIZATION_ID"])
  elsif ENV["HOST"].present?
    Decidim::Organization.find_by(host: ENV["HOST"])
  end
end
