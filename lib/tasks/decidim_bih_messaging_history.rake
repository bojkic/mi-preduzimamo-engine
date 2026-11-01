# frozen_string_literal: true

namespace :decidim_bih do
  namespace :messaging do
    desc "Aggregate delivery-history report for one organization. Read-only: it never sends, requeues, resets or drains."
    task :report, [:host] => :environment do |_task, args|
      host = args[:host].presence || abort("Usage: rake decidim_bih:messaging:report[HOST]")
      organization = Decidim::Organization.find_by!(host:)
      since = (ENV["SINCE_DAYS"].presence || 30).to_i.days.ago
      puts JSON.generate(Decidim::Bih::Messaging::Reconciliation.report(organization:, since:))
    end

    desc "Resolve ONE transport suppression, with the evidence that resolved it. Never clears one as a side effect."
    task :reactivate_suppression, [:host, :suppression_id] => :environment do |_task, args|
      host = args[:host].presence || abort("Usage: rake decidim_bih:messaging:reactivate_suppression[HOST,ID]")
      evidence = ENV["EVIDENCE"].presence || abort("Set EVIDENCE to the case or re-verification reference")
      organization = Decidim::Organization.find_by!(host:)
      suppression = Decidim::Bih::Messaging::Suppression.find_by!(
        id: args[:suppression_id], decidim_organization_id: organization.id
      )
      Decidim::Bih::Messaging::TransportSuppression.reactivate!(suppression, evidence:)
      puts "suppression=#{suppression.id} channel=#{suppression.channel} reactivated_at=#{suppression.reload.reactivated_at}"
    end
  end
end
