# frozen_string_literal: true

require "csv"

module Decidim
  module Bih
    module Admin
      # Read-mostly "Goodwill economy" dashboard for organization admins. Surfaces
      # the headline ledger figures (points issued, top earners, recent
      # redemptions), the PENDING volunteer-log verification queue, and two
      # write actions kept here behind the global-admin gate:
      #   * verify   — approve a pending volunteer log (awards the citizen points)
      #   * reverse  — post an append-only reversal of a transaction (Ledger#reverse)
      class GoodwillController < Decidim::Bih::Admin::ApplicationController
        # Read-model constants now live on Decidim::Bih::Goodwill::DashboardSummary
        # (the owner of these reads); re-exposed here for any caller that still
        # references the controller-level names.
        RECENT_LIMIT = Decidim::Bih::Goodwill::DashboardSummary::RECENT_LIMIT
        QUEUE_LIMIT = Decidim::Bih::Goodwill::DashboardSummary::QUEUE_LIMIT
        DASHBOARD_CACHE_TTL = Decidim::Bih::Goodwill::DashboardSummary::DASHBOARD_CACHE_TTL
        REWARD_FULFILLMENT_STATUS_FILTERS = (%w(open all) + Decidim::Bih::Goodwill::RewardFulfillment::STATUSES).freeze
        DEFAULT_REWARD_FULFILLMENT_STATUS_FILTER = "open"
        REWARD_FULFILLMENT_BATCH_STATUSES = %w(reserved fulfilled canceled).freeze
        WORKFLOW_TABS = %w(rewards matched_giving organization_spending reports ledger overview).freeze
        DEFAULT_WORKFLOW_TAB = "rewards"
        REWARD_FULFILLMENT_CSV_HEADERS = %w(
          id created_at citizen citizen_id reward_key reward_name cost status
          handled_at handled_by stock_remaining stock_total reward_expires_at
          ledger_transaction_id
        ).freeze

        before_action -> { require_bih_permission!(:goodwill_dashboard_read) }, only: [:index]
        before_action -> { require_bih_permission!(:volunteering_hours_review) }, only: [:verify_volunteer_log, :reject_volunteer_log, :correct_volunteer_log]
        before_action -> { require_bih_permission!(:volunteering_opportunity_review) }, only: [:approve_volunteer_opportunity, :reject_volunteer_opportunity]
        before_action -> { require_bih_permission!(:goodwill_reverse_transaction) }, only: [:reverse_transaction]
        before_action -> { require_bih_permission!(:match_request_create) }, only: [:create_match_request]
        before_action -> { require_bih_permission!(:match_request_decide) }, only: [:decide_match_request]
        before_action -> { require_bih_permission!(:organization_spending_decide) }, only: [:decide_organization_spending_request]
        before_action -> { require_bih_permission!(:match_payout_record) }, only: [:record_match_payout]
        before_action -> { require_bih_permission!(:reward_fulfillment_export) }, only: [:export_reward_fulfillments]
        before_action :require_reward_fulfillment_permission!, only: [:update_reward_fulfillment, :batch_update_reward_fulfillments]

        def index
          @goodwill_workflow_tabs = WORKFLOW_TABS
          @active_goodwill_tab = active_workflow_tab
          load_reward_fulfillment_filters
          load_reward_catalog
          load_dashboard
        end

        # Approve a pending volunteer-hours log. Re-homed here from the public
        # surface so the verification queue lives in one admin place. The award
        # itself stays idempotent in Decidim::Bih::VerifyVolunteerLog.
        def verify_volunteer_log
          log = Decidim::Bih::VolunteerLog
                .where(organization: current_organization)
                .find_by(id: params[:id])

          if params[:confirm_attendance] == "1" && !bih_allowed?(:volunteering_attendance_confirm)
            flash[:alert] = t(".verify_failed")
            return redirect_to volunteering_redirect_path(log)
          end

          if log && Decidim::Bih::VerifyVolunteerLog.call(log, verifier: current_user, confirm_attendance: params[:confirm_attendance] == "1") == :ok
            unless params[:confirm_attendance] == "1"
              audit_operator_action!(
                "volunteer_log_verified",
                permission: "volunteering_hours_review",
                resource: log,
                metadata: { hours: log.hours, opportunity_id: log.decidim_bih_volunteer_opportunity_id }
              )
            end
            flash[:notice] = t(".verified")
          else
            flash[:alert] = t(".verify_failed")
          end
          redirect_to volunteering_redirect_path(log)
        end

        def reject_volunteer_log
          log = Decidim::Bih::VolunteerLog
                .where(organization: current_organization)
                .find_by(id: params[:id])

          if Decidim::Bih::RejectVolunteerLog.call(log, verifier: current_user, reason: params[:rejection_reason]) == :ok
            audit_operator_action!(
              "volunteer_log_rejected",
              permission: "volunteering_hours_review",
              resource: log,
              metadata: { reason_present: params[:rejection_reason].to_s.strip.present? }
            )
            flash[:notice] = t(".rejected")
          else
            flash[:alert] = t(".reject_failed")
          end
          redirect_to volunteering_redirect_path(log)
        end

        def correct_volunteer_log
          log = Decidim::Bih::VolunteerLog.where(organization: current_organization).find_by(id: params[:id])
          result = Decidim::Bih::CorrectVolunteerLog.call(log, verifier: current_user, reason: params[:reason])
          if result == :ok
            flash[:notice] = t("decidim.bih.admin.volunteering.workspace.correction_done")
          else
            flash[:alert] = t("decidim.bih.admin.volunteering.workspace.correction_failed")
          end
          redirect_to volunteering_redirect_path(log)
        end

        def approve_volunteer_opportunity
          opportunity = Decidim::Bih::VolunteerOpportunity
                        .where(organization: current_organization)
                        .find_by(id: params[:id])
          result = Decidim::Bih::ApproveVolunteerOpportunity.call(
            opportunity, reviewer: current_user, confirm_partner: params[:confirm_partner] == "1"
          ) if opportunity

          if [:ok, :already].include?(result)
            audit_operator_action!(
              "volunteer_opportunity_approved",
              permission: "volunteering_opportunity_review",
              resource: opportunity,
              metadata: { already: result == :already }
            )
            flash[:notice] = t(".approved")
          else
            flash[:alert] = t(".approve_failed")
          end
          redirect_to volunteering_redirect_path(opportunity)
        end

        def reject_volunteer_opportunity
          opportunity = Decidim::Bih::VolunteerOpportunity
                        .where(organization: current_organization)
                        .find_by(id: params[:id])
          result = Decidim::Bih::RejectVolunteerOpportunity.call(
            opportunity,
            reviewer: current_user,
            reason: params[:rejection_reason]
          )

          if result == :ok || result == :already
            audit_operator_action!(
              "volunteer_opportunity_rejected",
              permission: "volunteering_opportunity_review",
              resource: opportunity,
              metadata: { already: result == :already, reason_present: params[:rejection_reason].to_s.strip.present? }
            )
            flash[:notice] = t(".rejected")
          else
            flash[:alert] = t(".reject_failed")
          end
          redirect_to volunteering_redirect_path(opportunity)
        end

        # Append-only correction: post a mirror-image transaction reversing the
        # target. Never edits/deletes the original (the ledger is immutable).
        def reverse_transaction
          unless private_action_reason.valid?
            flash[:alert] = private_action_reason_error
            return redirect_to goodwill_dashboard_path(tab: "ledger", anchor: "goodwill-transactions")
          end

          txn = Decidim::Bih::Goodwill::Transaction
                .where(organization: current_organization)
                .find_by(id: params[:id])

          if txn.nil?
            flash[:alert] = t(".reverse_failed")
          elsif txn.kind == "adjustment" || txn.reversing? || already_reversed?(txn)
            # Don't reverse an adjustment or a reversal, and don't reverse the
            # same txn twice (a double-click would otherwise post another mirror
            # debit). Matches the per-citizen reverse guard on CitizensController.
            flash[:alert] = t(".already_reversed")
          else
            Decidim::Bih::Goodwill::Transaction.transaction do
              reversal = Decidim::Bih::Goodwill::AwardDispatch.reverse_transaction(
                txn, actor: current_user,
                fulfillment_metadata: { action: "ledger_reverse", **private_action_reason.metadata }
              )
              audit_operator_action!(
                "goodwill_transaction_reversed",
                permission: "goodwill_reverse_transaction",
                resource: txn,
                metadata: {
                  reversal_transaction_id: reversal&.id,
                  transaction_kind: txn.kind,
                  **private_action_reason.metadata
                }
              )
            end
            pending_recovery = Decidim::Bih::Goodwill::CreditCorrection.where(original_transaction_id: txn.id).order(id: :desc).first&.settlement&.status == "admin_pending"
            flash[:notice] = t(".reversed")
            flash[:notice] = t("decidim.bih.admin.goodwill_corrections.statuses.admin_pending") if pending_recovery
          end
          redirect_to goodwill_dashboard_path(tab: "ledger", anchor: "goodwill-transactions")
        rescue ActiveRecord::RecordNotUnique
          # Lost a concurrent double-reverse race; the reversal already exists.
          flash[:alert] = t(".already_reversed")
          redirect_to goodwill_dashboard_path(tab: "ledger", anchor: "goodwill-transactions")
        rescue StandardError => e
          Rails.logger.error("[Admin::Goodwill] reverse failed for txn #{params[:id]}: #{e.class}: #{e.message}")
          flash[:alert] = t(".reverse_failed")
          redirect_to goodwill_dashboard_path(tab: "ledger", anchor: "goodwill-transactions")
        end

        # R13 — Matched giving: record a request to match a group/organization's
        # received goodwill with a real-world micro-grant. The actual grant stays
        # a MANUAL LFBN bookkeeping step (no Odoo write). +owner+ is resolved by
        # name/nickname within the current org — no raw ID exposed in the form.
        def create_match_request
          owner = resolve_owner_by_name(params[:owner_name].to_s.strip)
          points = params[:points].to_i

          if owner.nil?
            flash[:alert] = t(".match_owner_not_found")
            return redirect_to goodwill_dashboard_path(tab: "matched_giving", anchor: "goodwill-match-requests")
          end

          if owner == :ambiguous
            flash[:alert] = t(".match_owner_ambiguous")
            return redirect_to goodwill_dashboard_path(tab: "matched_giving", anchor: "goodwill-match-requests")
          end

          if points.positive?
            request = Decidim::Bih::Goodwill::MatchRequest.create!(
              organization: current_organization, owner:, points:,
              status: "pending", created_by: current_user
            )
            audit_operator_action!(
              "match_request_created",
              permission: "match_request_create",
              resource: request,
              metadata: { points:, owner_type: owner.class.base_class.name, owner_id: owner.id }
            )
            flash[:notice] = t(".match_requested")
          else
            flash[:alert] = t(".match_invalid")
          end
          redirect_to goodwill_dashboard_path(tab: "matched_giving", anchor: "goodwill-match-requests")
        rescue StandardError => e
          Rails.logger.error("[Admin::Goodwill] match request failed: #{e.class}: #{e.message}")
          flash[:alert] = t(".match_invalid")
          redirect_to goodwill_dashboard_path(tab: "matched_giving", anchor: "goodwill-match-requests")
        end

        # Approve/reject a pending match request. The grant itself remains manual;
        # this only stamps the decision. #decide! is a no-op if already decided.
        def decide_match_request
          request = Decidim::Bih::Goodwill::MatchRequest
                    .where(organization: current_organization)
                    .find_by(id: params[:id])
          decision = params[:decision].to_s

          decided = request&.decide!(decision, by: current_user) do
            audit_operator_action!(
              "match_request_decided",
              permission: "match_request_decide",
              resource: request,
              metadata: { decision: }
            )
          end
          if decided
            flash[:notice] = t(".match_decided")
            goodwill_notifier.match_request_decided(request, decision)
          else
            flash[:alert] = t(".match_decide_failed")
          end
          redirect_to goodwill_dashboard_path(tab: "matched_giving", anchor: "goodwill-match-requests")
        end

        # Record the manual payout/bookkeeping step after a match request is
        # approved. This does not write to Odoo or the Goodwill ledger.
        def record_match_payout
          request = Decidim::Bih::Goodwill::MatchRequest
                    .where(organization: current_organization)
                    .find_by(id: params[:id])

          recorded = request&.record_payout!(
            by: current_user,
            reference: params[:payout_reference],
            amount_minor_units: params[:payout_amount_minor_units],
            currency: params[:payout_currency],
            paid_on: params[:payout_paid_on],
            note: params[:payout_note]
          ) do
            audit_operator_action!(
              "match_payout_recorded",
              permission: "match_payout_record",
              resource: request,
              metadata: {
                amount_minor_units: request.payout_amount_minor_units,
                currency: request.payout_currency,
                paid_on: request.payout_paid_on&.to_s
              }.compact
            )
          end
          if recorded
            flash[:notice] = t(".payout_recorded")
          else
            flash[:alert] = t(".payout_failed")
          end
          redirect_to goodwill_dashboard_path(tab: "matched_giving", anchor: "goodwill-match-requests")
        end

        def decide_organization_spending_request
          request = Decidim::Bih::Goodwill::OrganizationSpendingRequest
                    .where(organization: current_organization)
                    .find_by(id: params[:id])

          Decidim::Bih::Goodwill::DecideOrganizationSpendingRequest.call(
            request,
            decision: params[:decision],
            decider: current_user,
            rejection_reason: params[:rejection_reason]
          ) do
            on(:ok) do |decided_request|
              audit_operator_action!(
                "organization_spending_request_decided",
                permission: "organization_spending_decide",
                resource: decided_request,
                metadata: {
                  decision: params[:decision],
                  request_type: decided_request.request_type,
                  points: decided_request.points
                }
              )
              flash[:notice] = t(".decided")
            end
            on(:insufficient) { flash[:alert] = t(".insufficient") }
            on(:invalid) { flash[:alert] = t(".failed") }
          end

          redirect_to goodwill_dashboard_path(tab: "organization_spending", anchor: "goodwill-organization-spending")
        end

        # Operational reward queue: the ledger spend is immutable, while the
        # handover status can move through requested/reserved/fulfilled/canceled.
        def update_reward_fulfillment
          fulfillment = Decidim::Bih::Goodwill::RewardFulfillment
                        .where(organization: current_organization)
                        .find_by(id: params[:id])
          status = params[:status].to_s

          unless private_reason_valid_for?(status)
            flash[:alert] = private_action_reason_error
            return redirect_to goodwill_dashboard_path(reward_fulfillment_redirect_params)
          end

          if fulfillment && REWARD_FULFILLMENT_BATCH_STATUSES.include?(status) && update_fulfillment_status(fulfillment, status)
            audit_operator_action!(
              "reward_fulfillment_updated",
              permission: status == "canceled" ? "goodwill_reverse_transaction" : "reward_fulfillment_update",
              resource: fulfillment,
              metadata: { status:, **private_reason_metadata_for(status) }
            )
            flash[:notice] = t(".reward_fulfillment_updated")
          else
            flash[:alert] = t(".reward_fulfillment_failed")
          end
          redirect_to goodwill_dashboard_path(reward_fulfillment_redirect_params)
        end

        def batch_update_reward_fulfillments
          status = params[:batch_status].to_s
          unless REWARD_FULFILLMENT_BATCH_STATUSES.include?(status)
            flash[:alert] = t(".invalid_status")
            return redirect_to goodwill_dashboard_path(reward_fulfillment_redirect_params)
          end

          ids = Array(params[:fulfillment_ids]).map(&:to_i).uniq
          if ids.empty?
            flash[:alert] = t(".no_selection")
            return redirect_to goodwill_dashboard_path(reward_fulfillment_redirect_params)
          end

          unless private_reason_valid_for?(status)
            flash[:alert] = private_action_reason_error
            return redirect_to goodwill_dashboard_path(reward_fulfillment_redirect_params)
          end

          updated = 0
          skipped = 0
          selected_scope = Decidim::Bih::Goodwill::RewardFulfillment
                           .where(organization: current_organization, id: ids)
          eligible_count = selected_scope.open.count
          selected_scope
            .find_each do |fulfillment|
              if fulfillment.open? && update_fulfillment_status(
                fulfillment,
                status,
                action: "batch",
                selected_count: ids.size,
                eligible_count:
              )
                audit_operator_action!(
                  "reward_fulfillment_updated",
                  permission: status == "canceled" ? "goodwill_reverse_transaction" : "reward_fulfillment_update",
                  resource: fulfillment,
                  metadata: {
                    status:,
                    action: "batch",
                    selected_count: ids.size,
                    eligible_count:,
                    **private_reason_metadata_for(status)
                  }
                )
                updated += 1
              else
                skipped += 1
              end
            end
          skipped += ids.size - updated - skipped

          flash[:notice] = t(".updated", count: updated, skipped:)
          redirect_to goodwill_dashboard_path(reward_fulfillment_redirect_params)
        end

        def export_reward_fulfillments
          load_reward_fulfillment_filters
          load_reward_catalog
          csv = reward_fulfillments_csv(
            filtered_reward_fulfillments
              .includes(:user, :handled_by, :ledger_transaction)
              .order(:created_at, :id)
          )

          send_data(
            csv,
            type: "text/csv; charset=utf-8",
            disposition: "attachment",
            filename: "reward-fulfillments-#{Time.current.utc.strftime("%Y%m%d%H%M%S")}.csv"
          )
        end

        private

        # Resolve an org user-group (or any user) by exact name or nickname match
        # within the current organization. Returns:
        #   - a Decidim::User when exactly one match is found
        #   - :ambiguous when more than one match is found (admin must be more specific)
        #   - nil when no match is found
        def resolve_owner_by_name(name)
          return nil if name.blank?

          matches = Decidim::Bih::PartnerProfile
                    .goodwill_eligible
                    .where(organization: current_organization)
                    .where("display_name = :n OR slug = :n", n: name)

          count = matches.count
          return nil if count.zero?
          return :ambiguous if count > 1

          matches.first
        end

        def require_reward_fulfillment_permission!
          status = params[:status].presence || params[:batch_status].presence
          permission = status.to_s == "canceled" ? :goodwill_reverse_transaction : :reward_fulfillment_update
          require_bih_permission!(permission)
        end

        def already_reversed?(txn)
          if txn.kind == "earn"
            return Decidim::Bih::Goodwill::SourceCreditCorrection.recognized_total(txn) <= 0
          end

          Decidim::Bih::Goodwill::Transaction
            .exists?(organization: current_organization, idempotency_key: "reversal_of:#{txn.id}")
        end

        def update_fulfillment_status(fulfillment, status, action: "single", selected_count: nil, eligible_count: nil)
          metadata = {
            action:,
            selected_count:,
            eligible_count:,
            **private_reason_metadata_for(status)
          }.compact

          if status == "canceled"
            cancel_fulfillment(fulfillment, metadata:)
          else
            # Capture open? before mark! so a double-submit on "fulfilled" only
            # fires one bell notification (idempotent mark! returns false the
            # second time but the guard below would still re-notify otherwise).
            was_open = fulfillment.open?
            result = fulfillment.mark!(status, by: current_user, metadata:)
            goodwill_notifier.reward_reserved(fulfillment) if result && was_open && status == "reserved"
            goodwill_notifier.reward_fulfilled(fulfillment) if result && was_open && status == "fulfilled"
            result
          end
        end

        def cancel_fulfillment(fulfillment, metadata: {})
          result = fulfillment.class.transaction do
            fulfillment.lock!
            next false unless fulfillment.open?

            if fulfillment.auto_issued?
              fulfillment.mark!("canceled", by: current_user, metadata: metadata.merge(refunded: 0))
            else
              txn = fulfillment.ledger_transaction
              next false unless txn

              Decidim::Bih::Goodwill::AwardDispatch.reverse_transaction(
                txn, actor: current_user, fulfillment_status: "canceled", fulfillment_source: "admin",
                fulfillment_metadata: metadata
              )
              true
            end
          end
          goodwill_notifier.reward_canceled(fulfillment) if result
          result
        end

        def private_action_reason
          @private_action_reason ||= Decidim::Bih::Admin::PrivateActionReason.new(params[:private_reason])
        end

        def private_reason_valid_for?(status)
          status != "canceled" || private_action_reason.valid?
        end

        def private_reason_metadata_for(status)
          status == "canceled" ? private_action_reason.metadata : {}
        end

        def private_action_reason_error
          t(
            "decidim.bih.admin.private_action_reason.invalid",
            count: Decidim::Bih::Admin::PrivateActionReason::MAX_LENGTH,
            default: "Enter a private operator reason (1–%{count} characters)."
          )
        end

        # Shared notifier owning the publish-and-swallow shell for goodwill bell
        # events (reward_reserved / reward_fulfilled / reward_canceled / matches).
        def goodwill_notifier
          @goodwill_notifier ||= Decidim::Bih::Admin::GoodwillNotifier.new
        end

        def load_reward_fulfillment_filters
          requested_status = params[:reward_fulfillment_status].to_s.presence || DEFAULT_REWARD_FULFILLMENT_STATUS_FILTER
          @reward_fulfillment_status_filter = REWARD_FULFILLMENT_STATUS_FILTERS.include?(requested_status) ? requested_status : DEFAULT_REWARD_FULFILLMENT_STATUS_FILTER
          @reward_fulfillment_reward_options = Decidim::Bih::Goodwill::RewardFulfillment
                                               .where(organization: current_organization)
                                               .distinct
                                               .order(:reward_key)
                                               .pluck(:reward_key)
          requested_reward = params[:reward_key].to_s.presence
          @reward_fulfillment_reward_filter = requested_reward if @reward_fulfillment_reward_options.include?(requested_reward)
        end

        def load_reward_catalog
          @reward_catalog_by_key = Decidim::Bih::Goodwill::RewardsCatalog
                                   .all(current_organization)
                                   .index_by(&:key)
        end

        def filtered_reward_fulfillments
          scope = Decidim::Bih::Goodwill::RewardFulfillment.where(organization: current_organization)
          scope = case @reward_fulfillment_status_filter
                  when "all"
                    scope
                  when "open"
                    scope.open
                  else
                    scope.where(status: @reward_fulfillment_status_filter)
                  end
          scope = scope.where(reward_key: @reward_fulfillment_reward_filter) if @reward_fulfillment_reward_filter.present?
          scope
        end

        def reward_fulfillment_redirect_params
          {
            tab: "rewards",
            reward_fulfillment_status: params[:reward_fulfillment_status].presence,
            reward_key: params[:reward_key].presence,
            anchor: "goodwill-reward-fulfillments"
          }.compact
        end

        def active_workflow_tab
          requested = params[:tab].to_s
          WORKFLOW_TABS.include?(requested) ? requested : DEFAULT_WORKFLOW_TAB
        end

        def volunteering_redirect_path(resource = nil)
          opportunity_id =
            if resource.respond_to?(:decidim_bih_volunteer_opportunity_id)
              resource.decidim_bih_volunteer_opportunity_id
            elsif resource.respond_to?(:id)
              resource.id
            end

          if opportunity_id.present?
            admin_bih_volunteer_opportunity_path(id: opportunity_id)
          else
            admin_bih_volunteering_path
          end
        end

        def reward_for(fulfillment)
          @reward_catalog_by_key[fulfillment.reward_key] ||
            Decidim::Bih::Goodwill::RewardsCatalog.find(fulfillment.reward_key, current_organization)
        end

        def reward_fulfillments_csv(fulfillments)
          CSV.generate(headers: true) do |csv|
            csv << REWARD_FULFILLMENT_CSV_HEADERS
            fulfillments.find_each { |fulfillment| csv << reward_fulfillment_csv_row(fulfillment) }
          end
        end

        def reward_fulfillment_csv_row(fulfillment)
          reward = reward_for(fulfillment)

          [
            fulfillment.id,
            csv_time(fulfillment.created_at),
            user_display_name(fulfillment.user),
            fulfillment.decidim_user_id,
            fulfillment.reward_key,
            reward_csv_name(reward, fulfillment),
            fulfillment.cost,
            fulfillment.status,
            csv_time(fulfillment.handled_at),
            user_display_name(fulfillment.handled_by),
            reward_remaining_stock(reward),
            reward_stock(reward),
            csv_time(fulfillment.reward_expires_at),
            ledger_transaction_id(fulfillment)
          ]
        end

        def reward_csv_name(reward, fulfillment)
          reward&.name || fulfillment.reward_key
        end

        def reward_remaining_stock(reward)
          reward&.remaining_stock(current_organization)
        end

        def reward_stock(reward)
          reward&.stock
        end

        def ledger_transaction_id(fulfillment)
          fulfillment.ledger_transaction&.id
        end

        def csv_time(value)
          value&.utc&.iso8601
        end

        def user_display_name(user)
          return nil if user.nil?

          user.try(:name).presence || user.try(:nickname).presence || "##{user.id}"
        end

        # Build the read model and fan its keys out onto the @ivars the dashboard
        # view consumes. The heavy lifting (cache key + versions, headline
        # figures, bounded queues, stale reports) lives in DashboardSummary.
        def load_dashboard
          Decidim::Bih::Goodwill::DashboardSummary.new(
            current_organization,
            reward_fulfillment_filters: {
              status: @reward_fulfillment_status_filter,
              reward_key: @reward_fulfillment_reward_filter
            }, history_page: params[:history_page], history_kind: params[:history_kind]).to_h.each do |key, value|
            instance_variable_set("@#{key}", value)
          end
        end
      end
    end
  end
end
