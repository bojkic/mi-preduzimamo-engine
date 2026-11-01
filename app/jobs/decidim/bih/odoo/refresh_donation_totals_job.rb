# frozen_string_literal: true

module Decidim
  module Bih
    module Odoo
      # Recomputes the donation totals from Odoo and writes them to Rails.cache,
      # off the request path. Scheduled periodically (e.g. every 30 min via
      # cron/sidekiq-scheduler) and also enqueued on-demand by
      # DonationTotals#cached on a cold cache. The config is passed in full so
      # the job rebuilds the exact same cache key the read path looks up.
      class RefreshDonationTotalsJob < Decidim::ApplicationJob
        queue_as :integrations

        retry_on Decidim::Bih::Odoo::Error,
                 wait: :polynomially_longer,
                 attempts: 5
        discard_on ActiveJob::DeserializationError

        def perform(product_ids:, confirmed_states:, date_from: nil,
                    currency: DonationTotals::DEFAULT_CURRENCY, cache_namespace: "global",
                    extra_domain: [])
          DonationTotals.new(
            product_ids: product_ids,
            confirmed_states: confirmed_states,
            date_from: date_from,
            currency: currency,
            cache_namespace: cache_namespace,
            extra_domain: extra_domain
          ).refresh!(raise_errors: true)
        end
      end
    end
  end
end
