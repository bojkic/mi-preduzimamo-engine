# frozen_string_literal: true

require "rails"

module Decidim
  module Bih
    # Declared up front so isolate_namespace can reference it at require-time,
    # before Zeitwerk autoloads the controllers under app/controllers/.../admin/.
    module Admin
    end

    # Permission-gated admin engine for the decidim-bih operator tools.
    # Mounted into Decidim::Core's routes at /admin/bih (the proven Decidim
    # pattern for adding org-wide admin pages without a component — mirrors how
    # e.g. decidim-decidim_awesome mounts its own AdminEngine). Controllers live
    # under Decidim::Bih::Admin and render inside Decidim's admin chrome.
    class AdminEngine < ::Rails::Engine
      isolate_namespace Decidim::Bih::Admin

      # This engine owns no migrations or rake tasks (they live in the main
      # Decidim::Bih::Engine); silence the host app from picking them up twice.
      paths["db/migrate"] = nil
      paths["lib/tasks"] = nil
      # Both engines live in this one gem, so Rails would otherwise associate the
      # gem's config/routes.rb (the PUBLIC engine's routes) with THIS engine too,
      # re-drawing it under the admin route set and colliding on route names
      # (e.g. reports_map). Clear it so only the inline `routes do` below applies.
      paths["config/routes.rb"] = []

      routes do
        resources :report_inbound_emails, path: "report-mail", only: [:index, :show] do
          post :history_import, on: :collection
          member do
            post :history
            post :link
            post :dismiss
            get "attachments/:attachment_id", action: :attachment, as: :attachment
          end
        end
        resources :report_service_senders, path: "report-senders", only: [:index, :create] do
          post :deactivate, on: :member
        end
        get "operations", to: "operations#index", as: :operations
        post "pending-registrations/:user_id/resend",
             to: "pending_registrations#resend", as: :pending_registration_resend
        get "goodwill", to: "goodwill#index", as: :goodwill_dashboard
        get "volunteering", to: "volunteering#index", as: :admin_bih_volunteering
        get "volunteering/opportunities/:id", to: "volunteering#show", as: :admin_bih_volunteer_opportunity
        post "volunteering/opportunities/:id/publish", to: "volunteering#publish_opportunity", as: :publish_volunteer_opportunity
        post "volunteering/opportunities/:id/return", to: "volunteering#return_opportunity", as: :return_volunteer_opportunity
        post "volunteering/opportunities/:id/manage", to: "volunteering#manage_opportunity", as: :manage_volunteer_opportunity
        post "volunteering/applications/:id/decide", to: "volunteering#decide_application", as: :decide_volunteer_application
        get "community-contributions",
            to: "community_contributions#index", as: :community_contributions
        post "community-contributions/projects/:id/approve",
             to: "community_contributions#approve_project", as: :approve_community_project
        post "community-contributions/projects/:id/reject",
             to: "community_contributions#reject_project", as: :reject_community_project
        post "community-contributions/projects/:id/request-changes",
             to: "community_contributions#request_project_changes", as: :request_changes_community_project
        post "community-contributions/needs/:id/approve",
             to: "community_contributions#approve_need", as: :approve_contribution_need
        post "community-contributions/needs/:id/reject",
             to: "community_contributions#reject_need", as: :reject_contribution_need
        post "community-contributions/offers/:id/:decision",
             to: "community_contributions#manage_offer",
             constraints: { decision: /recognize/ },
             as: :manage_contribution_offer
        get "volunteering/attendance",
            to: "volunteering#attendance", as: :volunteer_attendance
        post "volunteering/attendance",
             to: "volunteering#confirm_attendance_token", as: :confirm_volunteer_attendance
        post "volunteering/signup/:id/confirm-attendance",
             to: "volunteering#confirm_attendance", as: :confirm_volunteer_signup_attendance
        patch "volunteering/series/:series_key",
              to: "volunteering#update_series", as: :update_volunteer_series
        post "volunteering/series/:series_key/cancel",
             to: "volunteering#cancel_series", as: :cancel_volunteer_series
        post "volunteering/opportunity/:id/confirm-partner",
             to: "volunteering#confirm_partner", as: :confirm_partner_volunteer_opportunity
        post "goodwill/volunteer-log/:id/verify",
             to: "goodwill#verify_volunteer_log", as: :verify_volunteer_log_goodwill
        post "goodwill/volunteer-log/:id/reject",
             to: "goodwill#reject_volunteer_log", as: :reject_volunteer_log_goodwill
        post "volunteering/bonus/:id/retry",
             to: "volunteering#retry_bonus", as: :retry_volunteer_bonus
        post "goodwill/volunteer-log/:id/correct",
             to: "goodwill#correct_volunteer_log", as: :correct_volunteer_log_goodwill
        post "goodwill/volunteer-opportunity/:id/approve",
             to: "goodwill#approve_volunteer_opportunity", as: :approve_volunteer_opportunity_goodwill
        post "goodwill/volunteer-opportunity/:id/reject",
             to: "goodwill#reject_volunteer_opportunity", as: :reject_volunteer_opportunity_goodwill
        post "goodwill/transaction/:id/reverse",
             to: "goodwill#reverse_transaction", as: :reverse_transaction_goodwill
        post "goodwill/match-request",
             to: "goodwill#create_match_request", as: :create_match_request_goodwill
        post "goodwill/match-request/:id/decide",
             to: "goodwill#decide_match_request", as: :decide_match_request_goodwill
        post "goodwill/match-request/:id/payout",
             to: "goodwill#record_match_payout", as: :record_match_payout_goodwill
        post "goodwill/organization-spending/:id/decide",
             to: "goodwill#decide_organization_spending_request",
             as: :decide_organization_spending_request_goodwill
        get "goodwill/reward-fulfillments/export",
            to: "goodwill#export_reward_fulfillments", as: :export_reward_fulfillments_goodwill
        post "goodwill/reward-fulfillments/batch",
             to: "goodwill#batch_update_reward_fulfillments", as: :batch_update_reward_fulfillments_goodwill
        post "goodwill/reward-fulfillment/:id/:status",
             to: "goodwill#update_reward_fulfillment", as: :update_reward_fulfillment_goodwill

        # Round 25 — Rewards catalog CRUD (table-backed, admin-managed)
        resources :rewards, only: [:index, :new, :create, :edit, :update],
                            controller: "rewards", as: :admin_bih_rewards do
          collection { post :catalog }
          member do
            post :activate
            post :deactivate
          end
        end

        # Round 8 — Report lifecycle triage
        get "report-collections", to: "report_collections#index", as: :admin_bih_report_collections
        post "report-collections", to: "report_collections#create"
        get "report-collections/:id", to: "report_collections#show", as: :admin_bih_report_collection
        patch "report-collections/:id", to: "report_collections#update"
        post "report-collections/:id/ready", to: "report_collections#ready", as: :admin_bih_report_collection_ready
        get "report-collections/:id/export", to: "report_collections#export", as: :admin_bih_report_collection_export
        post "report-collections/:id/submission", to: "report_collections#record_submission", as: :admin_bih_report_collection_submission
        patch "reports/:reference/location", to: "report_cases#location", as: :admin_bih_report_location
        patch "reports/:reference/planning", to: "report_cases#plan", as: :admin_bih_report_planning
        delete "reports/:reference/planning", to: "report_cases#unplan"
        get "report-routing-guides", to: "report_routing_guides#index", as: :admin_bih_report_routing_guides
        post "report-routing-guides", to: "report_routing_guides#create"
        patch "report-routing-guides/:id", to: "report_routing_guides#update", as: :admin_bih_report_routing_guide
        delete "report-routing-guides/:id", to: "report_routing_guides#destroy"
        post "report-evidence-shares/:id/revoke", to: "report_routing_guides#revoke_share", as: :admin_bih_report_evidence_share_revoke

        get "reports", to: "reports#index", as: :admin_bih_reports
        get "reports/batch", to: "report_review_batches#index", as: :admin_bih_report_review_batch
        post "reports/batch/preview", to: "report_review_batches#preview", as: :admin_bih_report_review_batch_preview
        post "reports/batch/confirm", to: "report_review_batches#confirm", as: :admin_bih_report_review_batch_confirm
        post "reports/:reference/decision", to: "report_decisions#create", as: :admin_bih_report_decision
        post "reports/:reference/tasks/:id/close", to: "report_tasks#close", as: :admin_bih_report_task_close
        post "reports/:reference/decision/confirm", to: "report_decisions#confirm", as: :admin_bih_report_decision_confirm
        post "reports/:reference/dispatch/:dispatch_id/reconcile", to: "report_decisions#reconcile", as: :admin_bih_report_dispatch_reconcile
        post "reports/:reference/review-proposals", to: "report_review_proposals#create", as: :admin_bih_report_review_proposals
        post "reports/:reference/review-proposals/:id/adopt", to: "report_review_proposals#adopt", as: :admin_bih_report_review_proposal_adopt
        get "reports/:reference/duplicate-candidates", to: "report_decisions#candidates", as: :admin_bih_report_duplicate_candidates
        get "reports/:reference", to: "reports#show", as: :admin_bih_report
        patch "reports/:reference/status",
              to: "reports#update_status", as: :admin_bih_report_status
        patch "reports/:reference/internal-note",
              to: "reports#update_internal_note", as: :admin_bih_report_internal_note
        patch "reports/:reference/duplicate",
              to: "reports#mark_duplicate", as: :admin_bih_report_duplicate
        delete "reports/:reference/duplicate",
               to: "reports#clear_duplicate", as: :admin_bih_report_duplicate_clear
        post "reports/:reference/retry-forwarding",
             to: "reports#retry_forwarding", as: :admin_bih_report_retry

        patch "reports/:reference/case", to: "report_cases#update", as: :admin_bih_report_case
        post "reports/:reference/messages", to: "report_cases#message", as: :admin_bih_report_case_messages
        get "reports/:reference/forward-preview", to: "report_cases#preview", as: :admin_bih_report_forward_preview
        post "reports/:reference/forward", to: "report_cases#forward", as: :admin_bih_report_forward
        post "reports/:reference/external-submission", to: "report_cases#record_external", as: :admin_bih_report_external_submission

        # Round 11 — Citizen lookup + manual award
        # Round 25 (W4.7) — identity-panel correction actions (unlink Viber,
        # clear komšiluk). POST-only, CSRF-protected, global-admin gated.
        get "citizens", to: "citizens#index", as: :admin_bih_citizens
        get "citizens/:id", to: "citizens#show", as: :admin_bih_citizen
        post "citizens/:id/award", to: "citizens#award", as: :award_admin_bih_citizen
        post "citizens/:id/unlink-viber",
             to: "citizens#unlink_viber", as: :unlink_viber_admin_bih_citizen
        post "citizens/:id/clear-komsiluk",
             to: "citizens#clear_komsiluk", as: :clear_komsiluk_admin_bih_citizen
        # Per-citizen reversal of a mistaken/abusive ledger entry, reviewed in the
        # context of one citizen's profile (the dashboard has a global twin). Posts
        # an idempotent mirror "adjustment" via Goodwill::Ledger#reverse.
        post "citizens/:id/reverse/:transaction_id",
             to: "citizens#reverse_transaction", as: :reverse_transaction_admin_bih_citizen

        # Organization/operator governance.
        resources :operator_roles, only: [:index, :create], path: "operator-roles" do
          member do
            post :revoke
          end
        end
        resources :operator_audit_events, only: [:index], path: "operator-audit"
        resources :partner_profiles, only: [:index, :new, :create, :show, :edit, :update], path: "organizations" do
          member do
            get :memberships
            post :verify
            post :reject
            post :suspend
            post :restore
          end
          resources :memberships, only: [:create, :update, :destroy], controller: "partner_memberships"
        end
        resources :operator_messages, only: [:new, :create], path: "messages"

        # Round 25 (W4.5) — read-only integrations health/status page.
        get "integrations", to: "integrations#index", as: :admin_bih_integrations

        # PII-safe internal analytics exports.
        get "analytics", to: "analytics#index", as: :admin_bih_analytics
        get "analytics/export/:dataset",
            to: "analytics#export", as: :admin_bih_analytics_export

        # Read-only privacy retention status and dry-run counts.
        get "privacy-retention",
            to: "privacy_retention#index", as: :admin_bih_privacy_retention
        get "governance", to: "governance#index", as: :governance
        post "governance/:governance_kind/approvals",
             to: "governance#create", as: :governance_approvals

        resources :goodwill_corrections, path: "goodwill/corrections", only: [:index, :create] do
          collection { get :preview }
          member { post :settle }
        end

        resource :race, only: [:show], controller: :race do
          post :baseline
          post :capture
          post :decide
          post :finalize
          post :visibility
          post :settings
          post :membership
          get :evidence
        end

        # Round 25 (W4.2) — Goodwill earning schedule / daily caps / season.
        get "goodwill-settings", to: "goodwill_settings#edit", as: :goodwill_settings
        patch "goodwill-settings", to: "goodwill_settings#update"

        # Round 25 (W4.3) — local-area (MZ / komšiluk) contact editor.
        get "local-areas", to: "local_areas#index", as: :local_areas
        get "local-areas/:id/edit", to: "local_areas#edit", as: :edit_local_area
        patch "local-areas/:id", to: "local_areas#update", as: :local_area

        # Round 25 (W4.4) — Sistem 48 forwarding-target editor.
        get "sistem48-settings", to: "sistem48_settings#edit", as: :sistem48_settings
        patch "sistem48-settings", to: "sistem48_settings#update"

        # Durable staff publications and exact, explicit optional phone follow-up.
        get "board-notices/new", to: "board_notices#new", as: :new_admin_bih_board_notice
        post "board-notices/preview", to: "board_notices#preview", as: :admin_bih_board_notices_preview
        post "board-notices/confirm", to: "board_notices#confirm", as: :admin_bih_board_notices_confirm
        get "board-notices/settings", to: "board_notices#settings", as: :admin_bih_board_notice_settings
        patch "board-notices/settings", to: "board_notices#update_settings"
        get "board-notices/:id/edit", to: "board_notices#edit", as: :edit_admin_bih_board_notice
        post "board-notices/:id/correction-preview", to: "board_notices#preview_correction", as: :admin_bih_board_notice_correction_preview
        get "board-notices/:id/phone", to: "board_notices#phone", as: :admin_bih_board_notice_phone
        post "board-notices/:id/phone", to: "board_notices#preview_phone"

        # Historical broadcast entry points now lead to durable board publishing.
        get "broadcasts/new", to: "broadcasts#new", as: :new_admin_bih_broadcast
        post "broadcasts", to: "broadcasts#create", as: :admin_bih_broadcasts

        # Provjera jednokratnog ulaznog koda pozivnice na vratima lansiranja.
        get "pozivnice/provjera", to: "invitation_checkins#new", as: :new_invitation_checkin
        post "pozivnice/provjera", to: "invitation_checkins#create", as: :invitation_checkin

        # Komšiluk board moderation
        get "komsiluk-posts",
            to: "komsiluk_posts#index", as: :admin_bih_komsiluk_posts
        patch "komsiluk-posts/notification-policy",
              to: "komsiluk_posts#update_notification_policy",
              as: :admin_bih_komsiluk_notification_policy
        get "komsiluk-posts/:id/photo", to: "komsiluk_post_photos#show", as: :admin_bih_komsiluk_post_photo
        get "komsiluk-posts/:id", to: "komsiluk_posts#show", as: :admin_bih_komsiluk_post
        post "komsiluk-posts/:id/decision", to: "komsiluk_posts#decide", as: :admin_bih_komsiluk_post_decision
        post "komsiluk-posts/:id/hide",
             to: "komsiluk_posts#hide", as: :admin_bih_komsiluk_post_hide
        post "komsiluk-posts/:id/unhide",
             to: "komsiluk_posts#unhide", as: :admin_bih_komsiluk_post_unhide

        root to: "operations#index"
      end

      initializer "decidim_bih.admin_mount_routes" do
        Decidim::Core::Engine.routes do
          mount Decidim::Bih::AdminEngine, at: "/admin/bih", as: "decidim_admin_bih"
        end
      end

      # Admin-sidebar entry for the dashboard. The block is instance_exec'd in
      # the admin view context, so decidim_admin_bih.* helpers and current_user
      # are available. Visibility gated on superadmin, matching the controller's
      # v1 gate. The "copper-coin-line" icon is registered by the main engine's
      # decidim_bih.goodwill_icons initializer.
      initializer "decidim_bih.admin_menu" do
        Decidim.menu :admin_menu do |menu|
          menu.add_item :bih_operations,
                        I18n.t("decidim.bih.admin.navigation.title", default: "MI operations"),
                        decidim_admin_bih.operations_path,
                        icon_name: "community-line",
                        position: 9.45,
                        active: [%w(decidim/bih/admin/operations), []],
                        if: Decidim::Bih::OperatorAuthorization.allowed?(
                          current_user,
                          :operations_read,
                          organization: current_organization
                        )
          menu.add_item :bih_goodwill,
                        I18n.t("menu.goodwill", scope: "decidim.bih.admin"),
                        decidim_admin_bih.goodwill_dashboard_path,
                        icon_name: "copper-coin-line",
                        position: 9.5,
                        active: [%w(decidim/bih/admin/goodwill), []],
                        if: Decidim::Bih::OperatorAuthorization.allowed?(
                          current_user,
                          :goodwill_dashboard_read,
                          organization: current_organization
                        )
          # Round 25 (W4.6) — direct sidebar entries for the operator surfaces.
          # Previously these were reachable only via Goodwill-dashboard buttons.
          menu.add_item :bih_reports,
                        I18n.t("menu.reports", scope: "decidim.bih.admin"),
                        decidim_admin_bih.admin_bih_reports_path,
                        icon_name: "file-list-3-line",
                        position: 9.7,
                        active: [%w(decidim/bih/admin/reports), []],
                        if: Decidim::Bih::OperatorAuthorization.allowed?(
                          current_user,
                          :reports_read,
                          organization: current_organization
                        )
          menu.add_item :bih_komsiluk_posts,
                        I18n.t("menu.komsiluk_posts", scope: "decidim.bih.admin"),
                        decidim_admin_bih.admin_bih_komsiluk_posts_path,
                        icon_name: "flag-line",
                        position: 10.0,
                        active: [%w(decidim/bih/admin/komsiluk_posts), []],
                        if: Decidim::Bih::OperatorAuthorization.allowed?(
                          current_user,
                          :komsiluk_posts_read,
                          organization: current_organization
                        )
        end
      end
    end
  end
end
