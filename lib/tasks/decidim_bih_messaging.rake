# frozen_string_literal: true

require "json"

namespace :decidim_bih do
  namespace :messaging do
    desc "Read-only canonical topic preference counts (legacy matrix import is retired)"
    task :backfill, [:host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by(host: args[:host])
      abort "unknown organization host: #{args[:host].inspect}" if organization.nil?
      apply = ENV.fetch("APPLY", "0") == "1"

      abort "Legacy matrix import is retired; use the reviewed topic-consolidation migration" if apply

      summary = Decidim::Bih::Messaging::Backfill.new(
        organization:, apply:,
        batch_size: Integer(ENV.fetch("BATCH_SIZE", Decidim::Bih::Messaging::Backfill::DEFAULT_BATCH_SIZE)),
        resume: ENV.fetch("RESUME", "1") == "1"
      ).run!

      # Aggregate counts only. No citizen, no address, no stored value.
      puts JSON.pretty_generate(summary.to_h)
    end

    desc "Read-only contextual comparison of legacy and candidate delivery decisions"
    task :shadow_compare, [:host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by(host: args[:host])
      abort "unknown organization host: #{args[:host].inspect}" if organization.nil?
      samples = Decidim::Bih::Messaging::ShadowCompare.build_samples(
        organization:, limit: Integer(ENV.fetch("LIMIT", "200"))
      )
      report = Decidim::Bih::Messaging::ShadowCompare.new(
        organization:, samples:, mode: ENV.fetch("MODE", Decidim::Bih::Messaging::Modes::COMPATIBILITY)
      ).run

      puts JSON.pretty_generate(report.to_h)
      # A comparison that cannot explain its own differences is a stop signal,
      # not a report to file away.
      abort "unexplained differences: #{report.unexplained.length}" if ENV.fetch("FAIL_ON_DIFF", "1") == "1" && !report.explained?
    end

    desc "Correlation and uncertainty diagnostics for the enrolled pilot"
    task :diagnostics, [:host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by(host: args[:host])
      abort "unknown organization host: #{args[:host].inspect}" if organization.nil?
      window = Integer(ENV.fetch("HOURS", "24")).hours
      puts JSON.pretty_generate(
        Decidim::Bih::Messaging::DispatchEvidence.diagnostics(organization:, since: window.ago)
      )
    end
  end
end
