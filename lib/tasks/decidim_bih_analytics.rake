# frozen_string_literal: true

namespace :decidim_bih do
  namespace :analytics do
    desc "Email each org's operator an opt-in PII-safe internal analytics digest. " \
         "Recipient resolves per org via Setting namespace \"analytics\", key \"operator_email\". " \
         "Global fallback requires BIH_ANALYTICS_DIGEST_ENABLED=1 and BIH_ANALYTICS_DIGEST_EMAIL."
    task digest: :environment do
      global_enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("BIH_ANALYTICS_DIGEST_ENABLED", nil))
      env_recipient = global_enabled ? ENV.fetch("BIH_ANALYTICS_DIGEST_EMAIL", nil) : nil

      Decidim::Organization.find_each do |org|
        recipient = Decidim::Bih::Setting.namespace_for(org, "analytics")["operator_email"].presence || env_recipient
        if recipient.blank?
          # "skipped=no_opt_in_recipient" is the token script/mi_cron_health_smoke
          # already greps this log for. It was never emitted, so six months of
          # runs that delivered nothing to nobody were monitored as healthy.
          # The wording after the token is for humans; the token is the contract.
          Rails.logger.info "[decidim_bih:analytics:digest] skipped=no_opt_in_recipient host=#{org.host} " \
                            "- no analytics operator_email and no global fallback; owner must configure an opt-in recipient"
          next
        end

        summary = Decidim::Bih::Admin::AnalyticsSummary.new(organization: org)
        Decidim::Bih::Admin::AnalyticsDigestMailer.digest(
          organization: org,
          recipient:,
          summary:
        ).deliver_now
        Rails.logger.info "[decidim_bih:analytics:digest] sent digest for #{org.host}: " \
                          "#{summary.overview.values.sum} aggregate row(s)"
      end
    end
  end
end
