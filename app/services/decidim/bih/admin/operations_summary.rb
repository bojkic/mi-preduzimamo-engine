# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Lightweight counts and operator handoffs for the MI admin dashboard.
      # Every read is defensive so the dashboard remains usable during partial
      # installs, generated-host tests, or missing optional host tables.
      class OperationsSummary
        def initialize(organization:)
          @organization = organization
        end

        def metrics_by_item
          {
            "reports" => count_metric(report_attention_count, "reports_attention"),
            "komsiluk_posts" => count_metric(komsiluk_moderation_count, "moderation_needed"),
            "volunteering" => count_metric(volunteering_review_count, "review_needed"),
            "community_contributions" => count_metric(community_contributions_review_count, "review_needed"),
            "goodwill" => count_metric(goodwill_queue_count, "actions_needed"),
            "rewards" => count_metric(rewards_count, "active_rewards", tone: "neutral"),
            "citizens" => count_metric(citizens_count, "citizen_profiles", tone: "neutral"),
            "local_areas" => count_metric(local_areas_count, "local_areas", tone: "neutral"),
            "operator_roles" => count_metric(active_operator_roles_count, "active_roles", tone: "neutral"),
            "city_alerts" => count_metric(city_alerts_review_count, "review_needed", note: city_alerts_missed_note),
            "analytics" => status_metric("open_exports", "neutral"),
            "integrations" => status_metric("open_health_review", "neutral"),
            "privacy_retention" => count_metric(privacy_retention_count, "retention_eligible"),
            "governance" => governance_status_metric,
            "postal_queue" => status_metric("external_queue", "neutral"),
            "goodwill_settings" => status_metric("admin_only", "neutral"),
            "sistem48_settings" => status_metric("admin_only", "neutral"),
            "partner_profiles" => count_metric(partner_profiles_count, "organizations", tone: "neutral"),
            "operator_audit" => status_metric("audit_log", "neutral"),
            "operator_messages" => status_metric("audited_send", "neutral")
          }.compact
        end

        def handoffs
          [
            handoff(
              "viber_launch",
              "viber_launch_title",
              "viber_launch_body",
              "manual_approval",
              "script/mi_viber_launch_readiness_smoke"
            ),
            handoff(
              "external_chat_launch",
              "external_chat_launch_title",
              "external_chat_launch_body",
              "manual_approval",
              "script/mi_omnichannel_chat_readiness_smoke"
            ),
            handoff(
              "privacy_retention",
              "privacy_retention_title",
              "privacy_retention_body",
              "dry_run_required",
              "docs/operations/privacy-retention-sweeps.md"
            ),
            handoff(
              "release_restart",
              "release_restart_title",
              "release_restart_body",
              "owner_approval",
              "docs/operations/release-approval-policy.md"
            ),
            handoff(
              "backup_restore",
              "backup_restore_title",
              "backup_restore_body",
              "monthly_check",
              "script/mi_restore_drill"
            )
          ]
        end

        private

        attr_reader :organization

        def report_attention_count
          Decidim::Bih::Admin::ReportTriageSummary
            .new(organization:)
            .rows
            .sum { |row| row[:count].to_i }
        rescue StandardError
          nil
        end

        def komsiluk_moderation_count
          count_relation("Decidim::Bih::KomsilukPost") do |klass|
            Decidim::Bih::Komsiluk::ModerationQueue.needs_review(klass.where(organization:))
          end
        end

        def volunteering_review_count
          safe_count_sum(
            count_relation("Decidim::Bih::VolunteerOpportunity") { |klass| klass.pending_review.where(organization:) },
            count_relation("Decidim::Bih::VolunteerLog") { |klass| klass.pending.where(organization:) }
          )
        end

        def goodwill_queue_count
          safe_count_sum(
            count_relation("Decidim::Bih::Goodwill::RewardFulfillment") { |klass| klass.open.where(organization:) },
            count_relation("Decidim::Bih::Goodwill::MatchRequest") { |klass| klass.pending.where(organization:) },
            count_relation("Decidim::Bih::Goodwill::MatchRequest") { |klass| klass.approved.unpaid.where(organization:) },
            count_relation("Decidim::Bih::Goodwill::OrganizationSpendingRequest") { |klass| klass.pending.where(organization:) },
            count_relation("Decidim::Bih::Report") { |klass| klass.forwarding_attention.where(organization:) }
          )
        end

        def community_contributions_review_count
          safe_count_sum(
            count_relation("Decidim::Bih::PartnerProjectSubmission") do |klass|
              klass.pending_review.where(organization:)
            end,
            count_relation("Decidim::Bih::ContributionNeed") do |klass|
              klass.where(organization:, review_status: "pending")
            end,
            count_relation("Decidim::Bih::ContributionOffer") do |klass|
              klass.where(organization:, status: "confirmed", recognized_at: nil)
            end
          )
        end

        def rewards_count
          count_relation("Decidim::Bih::Goodwill::Reward") { |klass| klass.active.where(organization:) }
        end

        def citizens_count
          count_relation("Decidim::Bih::CitizenProfile") { |klass| klass.where(organization:) }
        end

        def local_areas_count
          count_relation("Decidim::Bih::LocalArea") { |klass| klass.where(organization:) }
        end

        def active_operator_roles_count
          count_relation("Decidim::Bih::OperatorRole") { |klass| klass.active.where(organization:) }
        end

        def partner_profiles_count
          count_relation("Decidim::Bih::PartnerProfile") { |klass| klass.where(organization:) }
        end

        # Deliberately NOT a `pending_review` row count. The host's workflow is
        # the single definition of the review queue, and it finishes an event
        # whose window has passed. Counting rows here instead showed operators
        # a tile that never matched the queue it linked to.
        def city_alerts_review_count
          workflow = "DecidimApp::Bijeljina::CityServiceWorkflow".safe_constantize
          return nil unless workflow.respond_to?(:review_count)

          workflow.review_count(organization:)
        rescue ActiveRecord::ActiveRecordError, NoMethodError
          nil
        end

        # Alerts whose window passed before anyone published them. They are
        # deliberately NOT added to the queue count — nothing can be done about
        # them now — but leaving them invisible is how five of them accumulated
        # unnoticed. Silence here means none, not "not counted": a failed read
        # returns nil and prints nothing.
        def city_alerts_missed_note
          workflow = "DecidimApp::Bijeljina::CityServiceWorkflow".safe_constantize
          return nil unless workflow.respond_to?(:expired_unpublished_count)

          count = workflow.expired_unpublished_count(organization:)
          return nil unless count.to_i.positive?

          t("metrics.expired_unpublished", total: count)
        rescue ActiveRecord::ActiveRecordError, NoMethodError
          nil
        end

        def privacy_retention_count
          Decidim::Bih::Admin::RetentionSummary
            .new(organization:)
            .summary[:total]
            .to_i
        rescue StandardError
          nil
        end

        def governance_status_metric
          klass = "Decidim::Bih::GovernanceApproval".safe_constantize
          return status_metric("no_data", "neutral") unless klass && table_available?(klass)

          latest_by_kind = klass.latest_by_kind(organization)
          total = klass::GOVERNANCE_KINDS.size
          latest = latest_by_kind.values.max_by(&:approved_at)
          metric_key, tone = governance_state(latest_by_kind, total)
          metric = status_metric(metric_key, tone)

          metric.merge(value: "#{latest_by_kind.size}/#{total}", updated_at: latest&.approved_at)
        rescue StandardError
          status_metric("no_data", "neutral")
        end

        def governance_state(latest_by_kind, total)
          approvals = latest_by_kind.values
          return %w(governance_blocked attention) if approvals.any? { |approval| approval.status == "blocked" }
          return %w(governance_follow_up attention) if approvals.any? { |approval| approval.status == "needs_follow_up" }
          return %w(governance_missing attention) if latest_by_kind.size < total
          return %w(governance_stale attention) if approvals.any?(&:stale?)

          %w(governance_approved ok)
        end

        def count_relation(class_name)
          klass = class_name.safe_constantize
          return nil unless klass && table_available?(klass)

          yield(klass).count
        rescue ActiveRecord::ActiveRecordError, NoMethodError
          nil
        end

        def table_available?(klass)
          return false unless klass.respond_to?(:table_exists?)

          klass.table_exists?
        rescue ActiveRecord::ActiveRecordError
          false
        end

        def safe_count_sum(*counts)
          usable = counts.compact
          return nil if usable.empty?

          usable.sum
        end

        def count_metric(value, label_key, tone: nil, note: nil)
          return status_metric("no_data", "neutral").merge(value: "—") if value.nil?

          {
            value:,
            label: t("metrics.#{label_key}"),
            tone: tone || (value.to_i.positive? ? "attention" : "ok"),
            updated_at: Time.current,
            note:
          }.compact
        end

        def status_metric(label_key, tone)
          { value: nil, label: t("metrics.#{label_key}"), tone:, updated_at: nil }
        end

        def handoff(id, title_key, body_key, status_key, command)
          {
            id:,
            title: t("handoffs.#{title_key}"),
            body: t("handoffs.#{body_key}"),
            status: t("handoffs.statuses.#{status_key}"),
            url: "/admin/bih/governance#governance-#{id}",
            command:
          }
        end

        def t(key, **values)
          I18n.t("decidim.bih.admin.operations_summary.#{key}", **values)
        end
      end
    end
  end
end
