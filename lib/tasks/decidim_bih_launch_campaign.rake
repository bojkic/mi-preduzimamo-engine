# frozen_string_literal: true

namespace :decidim_bih do
  namespace :launch do
    desc "Send one campaign message once per citizen. DRY_RUN=1 (default) only counts; DRY_RUN=0 sends."
    task :campaign, [:host, :key] => :environment do |_task, args|
      host = args[:host].presence || abort("usage: rake 'decidim_bih:launch:campaign[HOST,p8]'")
      key = args[:key].presence || abort("usage: rake 'decidim_bih:launch:campaign[HOST,p8]'")
      organization = Decidim::Organization.find_by(host:) || abort("no organization with host #{host}")

      # Dry run unless the operator says otherwise: the default must never be
      # the one that spends money.
      dry_run = ENV.fetch("DRY_RUN", "1") != "0"
      max_recipients = ENV.fetch("MAX_RECIPIENTS", Decidim::Bih::Launch::CampaignSend::DEFAULT_MAX_RECIPIENTS).to_i
      recipients = Decidim::Bih::Launch::CampaignRecipients.for(organization:, key:)

      result = Decidim::Bih::Launch::CampaignSend.new(
        organization:, key:, recipients:, dry_run:, max_recipients:, edition: ENV["CAMPAIGN_EDITION"]
      ).call

      # Counts only — never a name, a number or a body.
      puts "[launch:campaign] host=#{host} key=#{key} " + result.map { |name, value| "#{name}=#{value}" }.join(" ")
      puts "[launch:campaign] DRY RUN — re-run with DRY_RUN=0 to send" if result[:dry_run]
    end
  end
end
