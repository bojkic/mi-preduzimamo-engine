# frozen_string_literal: true
namespace :decidim_bih do
  namespace :goodwill do
    desc "Retry a bounded batch of pending source corrections and referral settlements"
    task recover_pending: :environment do
      host = ENV.fetch("HOST", "").strip
      abort "HOST is required" if host.empty?
      organization = Decidim::Organization.find_by!(host:)
      limit = Integer(ENV.fetch("LIMIT", "200"))
      abort "LIMIT must be 1..1000" unless limit.between?(1, 1000)
      Decidim::Bih::Goodwill::CorrectionIntent.pending.joins(:report).where(decidim_bih_reports: { decidim_organization_id: organization.id }).order(:id).limit(limit).pluck(:id).each do |id|
        Decidim::Bih::Goodwill::SourceCreditCorrectionJob.perform_later(id)
      end
      Decidim::Bih::Goodwill::CreditSettlement.where(notified_at: nil).joins(:credit_correction)
        .where(decidim_bih_goodwill_credit_corrections: { decidim_organization_id: organization.id }).order(:id).limit(limit)
        .pluck(:credit_correction_id).each { |id| Decidim::Bih::Goodwill::SourceCreditCorrectionNoticeJob.perform_later(id) }
      count = Decidim::Bih::Goodwill::Referrals.retry_pending(organization:, limit:)
      puts "Referral payments committed: #{count}"
    end
  end
end
