# frozen_string_literal: true
namespace :decidim_bih do
  namespace :race do
    desc "Refresh race cache; after cutoff capture immutable evidence (never finalize winners)"
    task :refresh, [:org_host, :mode] => :environment do |_task, args|
      organization = Decidim::Organization.find_by!(host: args[:org_host])
      config = Decidim::Bih::Race::Config.new(organization:)
      Decidim::Bih::Race::Review.new(organization).capture! if config.finished?
      written = Decidim::Bih::Race::Standings.new(organization).refresh!(force: args[:mode].to_s == "force")
      puts "Race cache: #{written} rows; final approval is an admin action."
      edition = Decidim::Bih::Race::Edition.for(organization)
      review_end = edition&.settings&.dig("review_closes_at")
      if review_end.present? && Time.current > Time.iso8601(review_end) && !edition.finalized_at
        warn "ERROR race review deadline passed without final sign-off"
      end
    end

    desc "Capture private race cutoff evidence; refuses before cutoff; never approves a winner"
    task :capture, [:org_host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by!(host: args[:org_host])
      edition = Decidim::Bih::Race::Review.new(organization).capture!
      puts "Race capture: #{edition.snapshot_digest}; actual capture #{edition.captured_at.utc.iso8601}"
    end

    desc "Finalization requires the admin review screen and its evidence/revision confirmation"
    task :freeze, [:org_host] => :environment do |_task, _args|
      abort "Use /admin/bih/race after reviewing cutoff evidence and setting review/vote dates. This task never finalizes."
    end
  end
end
