# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Grouped admin IA for BIH operator pages. The Decidim admin sidebar stays
      # intentionally small; this registry keeps every direct route discoverable.
      module Navigation
        class << self
          def groups(view_context:)
            groups = base_groups(view_context).map { |group| normalize_group(group) }
            merge_host_groups!(groups, host_groups(view_context))
            filter_groups_by_permissions(groups, view_context)
          end

          def items(view_context:)
            Array(groups(view_context:)).flat_map do |group|
              group = group.respond_to?(:to_h) ? group.to_h.symbolize_keys : {}
              Array(group[:items]).filter_map do |item|
                item.respond_to?(:to_h) ? item.to_h.symbolize_keys : nil
              end
            end
          end

          def item_for(view_context:, id:)
            id = id.to_s
            items(view_context:).find { |item| item[:id].to_s == id }
          end

          def breadcrumbs(view_context:, current_item:, current_step_label: nil)
            item = item_for(view_context:, id: current_item)
            dashboard_url = view_context.decidim_admin_bih.operations_path
            crumbs = [
              { id: "admin", label: t("admin", "Admin"), url: "/admin" },
              { id: "operations", label: t("title", "MI operations"), url: dashboard_url }
            ]

            if item
              crumbs << {
                id: "area_#{item[:area_id]}",
                label: item[:area_label],
                url: view_context.decidim_admin_bih.operations_path(open_tools: 1, anchor: "admin-navigation-group-#{item[:area_id]}")
              }
              crumbs << {
                id: item[:id],
                label: item[:breadcrumb_label].presence || item[:label],
                url: item[:url]
              }
            end

            Array(current_step_label).compact_blank.each_with_index do |label, index|
              crumbs << {
                id: "step_#{index}",
                label: label.to_s,
                url: nil
              }
            end

            crumbs
          end

          private

          def base_groups(view)
            [
              {
                id: "daily",
                label: t("daily", "Daily work"),
                items: [
                  item("reports", t("reports", "Citizen reports"), view.decidim_admin_bih.admin_bih_reports_path,
                       t("reports_description", "Filter the report queue and open review pages for status, duplicate, retry, and note actions."),
                       permission: :reports_read),
                  item("volunteering", t("volunteering", "Volunteering roster"), view.decidim_admin_bih.admin_bih_volunteering_path,
                       t("volunteering_description", "Review signups, waitlists, partner confirmation, and hours."),
                       permission: :volunteering_roster_read),
                  item("community_contributions", t("community_contributions", "Community contribution review"),
                       view.decidim_admin_bih.community_contributions_path,
                       t("community_contributions_description", "Review partner projects, non-cash needs, and confirmed offers before publication or recognition."),
                       permission: :community_contributions_read),
                  item("partner_profiles", t("partner_profiles", "Organizacije"), view.decidim_admin_bih.partner_profiles_path,
                       t("partner_profiles_description", "Review, verify, and maintain organization profiles."),
                       permission: :partner_profiles_manage),
                  item("postal_queue", t("postal_queue", "Postal verification queue"), "/admin/postal_letter/pending_authorizations",
                       t("postal_queue_description", "Print pending postal verification letters."),
                       permission: :privacy_retention_manage)
                ]
              },
              {
                id: "alerts",
                label: t("alerts", "Alerts and local notices"),
                items: [
                  item("komsiluk_posts", t("komsiluk_posts", "Komšiluk board"), view.decidim_admin_bih.admin_bih_komsiluk_posts_path,
                       t("komsiluk_posts_description", "Moderate neighbourhood posts and urgent local notices."),
                       permission: :komsiluk_posts_read),
                  item("staff_publication", t("staff_publication", "Staff publication"), view.decidim_admin_bih.new_admin_bih_board_notice_path,
                       t("staff_publication_description", "Publish lasting board notices and choose optional phone delivery."),
                       permission: :broadcast_preview)
                ]
              },
              {
                id: "community",
                label: t("community", "Community value"),
                items: [
                  item("goodwill", t("goodwill", "Goodwill economy"), view.decidim_admin_bih.goodwill_dashboard_path,
                       t("goodwill_description", "Wallet, rewards, fulfillment, reversals, and match requests."),
                       permission: :goodwill_dashboard_read),
                  item("goodwill_corrections", t("goodwill_corrections", "Point corrections"), view.decidim_admin_bih.goodwill_corrections_path,
                       t("goodwill_corrections_description", "Preview source corrections and review pending wallet recoveries."),
                       permission: :goodwill_reverse_transaction),
                  item("race", t("race", "Neighborhood race review"), view.decidim_admin_bih.race_path,
                       t("race_description", "Review contest membership, cutoff evidence, appeals and final results."),
                       permission: :goodwill_settings_manage),
                  item("rewards", t("rewards", "Rewards"), view.decidim_admin_bih.admin_bih_rewards_path,
                       t("rewards_description", "Manage the rewards catalog and stock."),
                       permission: :rewards_catalog_manage),
                  item("citizens", t("citizens", "Citizens"), view.decidim_admin_bih.admin_bih_citizens_path,
                       t("citizens_description", "Find a citizen, review trust status, and make manual adjustments."),
                       permission: :citizen_lookup),
                  item("operator_messages", t("operator_messages", "Messages"), view.decidim_admin_bih.new_operator_message_path,
                       t("operator_messages_description", "Send separately audited general support messages to users."),
                       permission: :general_support_message_send)
                ]
              },
              {
                id: "data",
                label: t("data", "Data and oversight"),
                items: [
                  item("integrations", t("integrations", "Integrations"), view.decidim_admin_bih.admin_bih_integrations_path,
                       t("integrations_description", "Provider health, city-data freshness, and admin-only dataset previews."),
                       permission: :integrations_read),
                  item("analytics", t("analytics", "Analytics exports"), view.decidim_admin_bih.admin_bih_analytics_path,
                       t("analytics_description", "PII-safe aggregate analytics exports."),
                       permission: :analytics_read),
                  item("privacy_retention", t("privacy_retention", "Privacy retention"), view.decidim_admin_bih.admin_bih_privacy_retention_path,
                       t("privacy_retention_description", "Retention buckets, dry-run counts, and privacy sweep readiness."),
                       permission: :privacy_retention_read),
                  item("operator_audit", t("operator_audit", "Operator audit"), view.decidim_admin_bih.operator_audit_events_path,
                       t("operator_audit_description", "Review append-only operator action history."),
                       permission: :operator_audit_read)
                ]
              },
              {
                id: "governance",
                label: t("governance", "Governance"),
                items: [
                  item("governance", t("governance_dashboard", "Governance readiness"), view.decidim_admin_bih.governance_path,
                       t("governance_dashboard_description", "Review release, Viber, backup, cron, and retention approval handoffs."),
                       permission: :operations_read)
                ]
              },
              {
                id: "settings",
                label: t("settings", "Settings"),
                items: [
                  item("goodwill_settings", t("goodwill_settings", "Goodwill settings"), view.decidim_admin_bih.goodwill_settings_path,
                       t("goodwill_settings_description", "Configure earning rules, daily caps, and season start."),
                       permission: :goodwill_settings_manage),
                  item("local_areas", t("local_areas", "Local areas"), view.decidim_admin_bih.local_areas_path,
                       t("local_areas_description", "Maintain MZ and Komšiluk contact/routing metadata."),
                       permission: :local_area_manage),
                  item("sistem48_settings", t("sistem48_settings", "Sistem 48 routing"), view.decidim_admin_bih.sistem48_settings_path,
                       t("sistem48_settings_description", "Configure report forwarding mailboxes."),
                       permission: :sistem48_settings_manage),
                  item("operator_roles", t("operator_roles", "Operator roles"), view.decidim_admin_bih.operator_roles_path,
                       t("operator_roles_description", "Grant, renew, and revoke expiring operator roles."),
                       permission: :operator_roles_manage)
                ]
              }
            ]
          end

          def host_groups(view)
            provider = Decidim::Bih.admin_navigation_provider
            return [] unless provider.respond_to?(:groups)

            Array(provider.groups(view_context: view))
          end

          def merge_host_groups!(groups, host_groups)
            host_groups.each do |host_group|
              normalized = normalize_group(host_group)
              next if normalized[:items].empty?

              group = groups.find { |candidate| candidate[:id] == normalized[:id] }
              if group
                group[:items].concat(normalized[:items])
              else
                groups << normalized
              end
            end
          end

          def normalize_group(group)
            hash = group.respond_to?(:to_h) ? group.to_h.symbolize_keys : {}
            id = hash.fetch(:id).to_s
            label = hash.fetch(:label).to_s
            {
              id:,
              label:,
              items: Array(hash[:items]).map { |entry| normalize_item(entry, area_id: id, area_label: label) }.compact
            }
          rescue KeyError
            { id: "", label: "", items: [] }
          end

          def normalize_item(entry, area_id: nil, area_label: nil)
            hash = entry.respond_to?(:to_h) ? entry.to_h.symbolize_keys : {}
            item(
              hash.fetch(:id).to_s,
              hash.fetch(:label).to_s,
              hash.fetch(:url).to_s,
              hash[:description].to_s,
              permission: hash[:permission],
              area_id: hash[:area_id].presence || area_id,
              area_label: hash[:area_label].presence || area_label,
              parent_id: hash[:parent_id],
              breadcrumb_label: hash[:breadcrumb_label],
              page_kind: hash[:page_kind],
              workflow_step: hash[:workflow_step]
            )
          rescue KeyError
            nil
          end

          def item(id, label, url, description, options = {})
            {
              id:,
              label:,
              url:,
              description:,
              permission: options[:permission]&.to_sym,
              area_id: options[:area_id]&.to_s,
              area_label: options[:area_label]&.to_s,
              parent_id: options[:parent_id]&.to_s,
              breadcrumb_label: options[:breadcrumb_label]&.to_s,
              page_kind: options[:page_kind]&.to_s,
              workflow_step: options[:workflow_step]&.to_s
            }.compact
          end

          def filter_groups_by_permissions(groups, view)
            groups.filter_map do |group|
              items = group[:items].select { |entry| visible_item?(entry, view) }
              next if items.empty?

              group.merge(items:)
            end
          end

          def visible_item?(entry, view)
            permission = entry[:permission]
            return true if permission.blank?
            return view.bih_allowed?(permission) if view.respond_to?(:bih_allowed?)

            Decidim::Bih::OperatorAuthorization.allowed?(
              view.current_user,
              permission,
              organization: view.current_organization
            )
          end

          def t(key, default)
            I18n.t("decidim.bih.admin.navigation.#{key}", default:)
          end
        end
      end
    end
  end
end
