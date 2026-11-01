# frozen_string_literal: true

# Fills only the BLANK locale slots of an existing i18n jsonb hash, yielding
# each locale code to compute the value. Existing (admin-edited) values are
# preserved; nil/blank yields from the block are skipped. Used by the rewards
# import task to seed title/description without clobbering operator edits.
def merge_blank_locales(existing, locales)
  result = (existing || {}).dup
  locales.each do |locale|
    code = locale.to_s
    next if result[code].present?

    value = yield(locale)
    result[code] = value if value.present?
  end
  result
end

namespace :decidim_bih do
  namespace :goodwill do
    desc "Verify cached goodwill account aggregates against the immutable ledger (FIX=1 to repair drift)"
    task reconcile: :environment do
      fix = ENV["FIX"] == "1"
      host = ENV["HOST"].to_s.strip
      abort "HOST is required so reconciliation cannot cross tenant boundaries" if host.blank?

      organization = Decidim::Organization.find_by(host:)
      abort "Organization not found for host: #{host}" unless organization

      approval = nil
      if fix
        approval = Decidim::Bih::GovernanceApproval.current_for(organization, "cron_maintenance")
        expected_scope = "goodwill-reconcile:#{Date.current.strftime("%Y-%m")}"
        unless approval&.scope_key == expected_scope
          abort "Current cron-maintenance approval with scope #{expected_scope} is required for FIX=1"
        end
      end
      rows = Decidim::Bih::Goodwill::Reconciliation.run(organization, fix:)
      drift = rows.length
      rows.each do |row|
        warn "account ##{row[:account_id]}: balance #{row[:balance_before]} -> #{row[:balance_after]}, " \
             "contribution #{row[:contribution_before]} -> #{row[:contribution_after]}"
      end
      if fix
        Decidim::Bih::OperatorAuditEvent.record!(
          organization:, actor: approval.user, event_type: "goodwill_reconciliation_completed",
          permission: "goodwill_manage", role: approval.approval_role,
          metadata: { fix: true, drift_count: drift, source: "rake", host_scoped: true }
        )
      end
      puts "#{drift} account(s) with drift#{fix ? " (repaired)" : " (read-only)"}."
    end

    desc "Print the goodwill measurement snapshot (last 7 days vs prior) per organization"
    task metrics: :environment do
      Decidim::Organization.find_each do |org|
        snap = Decidim::Bih::Goodwill::Metrics.new(org).snapshot
        puts "[#{org.name}] last #{snap[:window_days]}d vs prior:"
        snap[:current].each_key do |metric|
          puts "  #{metric}: #{snap[:current][metric]} (prev #{snap[:previous][metric]})"
        end
      end
    end

    desc "Reconcile native gamification badges from the goodwill ledger (drift-free reset_badges)"
    task reset_badges: :environment do
      Decidim::Gamification.reset_badges
      puts "Gamification badges reset from source-of-truth."
    end

    desc "Cancel open reward fulfillments whose reward expired >=7 days ago (with ledger reversal)"
    # Intended to run on a cron schedule (Track C). Only touches rows where
    # reward_expires_at is set AND is older than 7 days AND status is open
    # (requested/reserved). Each cancellation posts an append-only ledger
    # reversal and sends a bell notification to the citizen. Safe to run
    # multiple times — already-canceled rows are excluded by the scope.
    task cancel_expired_fulfillments: :environment do
      ledger = Decidim::Bih::Goodwill::Ledger.new
      canceled = 0
      errors = 0

      Decidim::Bih::Goodwill::RewardFulfillment
        .cancelable_expired
        .includes(:ledger_transaction, :user)
        .find_each do |fulfillment|
          notify = false

          ActiveRecord::Base.transaction do
            fulfillment.lock!
            next unless fulfillment.open? # double-check inside lock

            if fulfillment.auto_issued?
              fulfillment.mark!("canceled", by: nil, source: "background", actor_role: "system",
                                metadata: { action: "expired_reward_cancel", refunded: 0 })
            else
              txn = fulfillment.ledger_transaction
              raise "Redeemed fulfillment has no debit" unless txn

              ledger.reverse(txn, fulfillment_status: "canceled", fulfillment_source: "background",
                             fulfillment_metadata: { action: "expired_reward_cancel" })
            end
            notify = true
            canceled += 1
          end

          # Bell notification must run OUTSIDE the transaction so a mailer
          # failure never rolls back the status update that already committed.
          if notify
            begin
              reward = Decidim::Bih::Goodwill::RewardsCatalog.find(fulfillment.reward_key, fulfillment.organization)
              Decidim::EventsManager.publish(
                event: "decidim.events.bih.goodwill.reward_canceled",
                event_class: Decidim::Bih::Goodwill::RewardCanceledEvent,
                resource: fulfillment.user,
                affected_users: [fulfillment.user],
                force_send: true,
                extra: {
                  reward_name: reward&.name || fulfillment.reward_key,
                  refunded: fulfillment.auto_issued? ? 0 : fulfillment.cost
                }
              )
            rescue StandardError => e
              warn "Notification failed for fulfillment ##{fulfillment.id}: #{e.class}: #{e.message}"
            end
          end
        rescue StandardError => e
          errors += 1
          warn "Failed to cancel fulfillment ##{fulfillment.id}: #{e.class}: #{e.message}"
        end

      puts "#{canceled} fulfillment(s) canceled, #{errors} error(s)."
    end

    desc "Import the config rewards catalog (Decidim::Bih.goodwill_rewards_catalog) into the DB table for HOST (idempotent upsert by key)"
    # Round 25 — brings the live config-driven catalog under admin management
    # without losing it. Idempotent: re-running upserts by [organization, key],
    # carrying cost/stock/expires_at from config and seeding blank title/
    # description jsonb from the existing i18n names. Operator edits to title/
    # description are preserved on re-import (only blank locale slots are filled).
    #
    # Usage: bundle exec rake "decidim_bih:goodwill:import_rewards_catalog[host.example.org]"
    task :import_rewards_catalog, [:host] => :environment do |_t, args|
      host = args[:host].to_s.strip
      abort "Usage: rake decidim_bih:goodwill:import_rewards_catalog[HOST]" if host.blank?

      organization = Decidim::Organization.find_by(host:)
      abort "Organization not found for host: #{host}" unless organization

      locales = Array(organization.available_locales).presence || I18n.available_locales
      created = 0
      updated = 0

      Array(Decidim::Bih.goodwill_rewards_catalog).each do |row|
        row = row.symbolize_keys
        key = row[:key].to_s
        next if key.blank?

        reward = Decidim::Bih::Goodwill::Reward.find_or_initialize_by(
          organization:, key:
        )
        was_new = reward.new_record?

        reward.cost = row[:cost].to_i if row.has_key?(:cost)
        reward.stock = row[:stock]&.to_i if row.has_key?(:stock)
        reward.expires_at = row[:expires_at]&.to_time if row.has_key?(:expires_at)
        reward.active = true if reward.active.nil?

        # Seed title/description per locale from the legacy i18n keys, but only
        # for slots that are still blank so admin edits survive a re-import.
        # read_attribute is required because the model overrides #title/#description
        # to return a single localized String (the public read interface), whereas
        # here we need the raw locale-keyed jsonb hash.
        reward.title = merge_blank_locales(reward.read_attribute(:title), locales) do |locale|
          I18n.t("decidim.bih.goodwill.rewards.#{key}", locale:, default: key.humanize)
        end
        reward.description = merge_blank_locales(reward.read_attribute(:description), locales) do |locale|
          path = "decidim.bih.goodwill.reward_descriptions.#{key}"
          I18n.exists?(path, locale) ? I18n.t(path, locale:) : nil
        end

        reward.save!
        was_new ? created += 1 : updated += 1
      end

      puts "[#{organization.host}] rewards imported: #{created} created, #{updated} updated."
    end

    desc "Print aggregate read-only anomaly scan health and flag counts; case details remain in authorized admin"
    task anomalies: :environment do
      failed = false
      Decidim::Organization.find_each do |organization|
        report = Decidim::Bih::Goodwill::AnomalyScan.new(organization).report
        failed ||= report[:status] != "complete"
        counts = report[:flags].group_by { |flag| [flag[:type], flag[:severity]] }.transform_values(&:size)
        puts({ organization_id: organization.id, status: report[:status], since: report[:since],
               computed_at: report[:computed_at], detectors: report[:detectors], counts: }.to_json)
      end
      abort "Anomaly scan incomplete; inspect authorized dashboard" if failed
    end
  end
end
