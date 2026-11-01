# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Admin citizen lookup and manual award surface. Lets operators:
      #   GET  /admin/bih/citizens          -> search form (name/nickname/email)
      #   GET  /admin/bih/citizens/:id      -> account summary for one citizen
      #   POST /admin/bih/citizens/:id/award -> manual Goodwill award
      #
      # Permission: same global-admin gate as GoodwillController (admin? only).
      # Org-scoped throughout: no cross-org results ever surface.
      class CitizensController < Decidim::Bih::Admin::ApplicationController
        # A manual award publishes a points-earned bell with `force_send: true`
        # (`Goodwill::Ledger#notify_points_earned`). The reversal does NOT
        # notify, so it deliberately has no row here.
        AWARD_MESSAGE_CLASSES = %w(goodwill.points_earned).freeze

        include Decidim::Bih::Admin::ScopedFinder

        LEDGER_HISTORY_LIMIT = 20

        before_action -> { require_bih_permission!(:citizen_lookup) }, only: [:index, :show]
        before_action -> { require_bih_permission!(:goodwill_manual_award) }, only: [:award]
        before_action -> { require_bih_permission!(:citizen_identity_correction) }, only: [:unlink_viber, :clear_komsiluk]
        before_action -> { require_bih_permission!(:goodwill_reverse_transaction) }, only: [:reverse_transaction]

        # GET /admin/bih/citizens
        # Optional ?q= param to search by name, nickname, or email.
        def index
          @query = params[:q].to_s.strip
          @results = @query.present? ? search_users(@query) : []
        end

        # GET /admin/bih/citizens/:id
        def show
          @citizen = find_citizen!
          return unless @citizen

          load_ledger_context(@citizen) if bih_allowed?(:citizen_ledger_read)
          @award_consequences = Decidim::Bih::Messaging::SendConsequences.tolerant_for(AWARD_MESSAGE_CLASSES)
          load_identity_context(@citizen) if bih_allowed?(:citizen_identity_correction)
        end

        # POST /admin/bih/citizens/:id/award
        # params: amount (1..500), reason (required)
        def award
          @citizen = find_citizen!
          return unless @citizen

          amount = Decidim::Bih::Goodwill::RequestIdentity.amount(params[:amount])
          reason = params[:reason].to_s.strip

          unless (1..500).cover?(amount) && reason.present?
            flash[:alert] = t(".invalid_params")
            return redirect_to admin_bih_citizen_path(@citizen)
          end

          result = Decidim::Bih::Goodwill::AwardDispatch.manual_award(
            @citizen,
            amount:,
            admin: current_user,
            reason:, request_key: params[:request_key]
          )

          if result
            audit_operator_action!(
              "citizen_manual_award",
              permission: "goodwill_manual_award",
              resource: @citizen,
              metadata: { amount:, reason_present: reason.present? }
            )
            flash[:notice] = t(".awarded", amount:, name: @citizen.name.presence || @citizen.nickname)
          else
            flash[:alert] = t(".already_awarded")
          end
          redirect_to admin_bih_citizen_path(@citizen)
        rescue StandardError => e
          Rails.logger.error("[Admin::Citizens] award failed for citizen #{@citizen&.id}: #{e.class}: #{e.message}")
          flash[:alert] = t(".award_failed")
          redirect_to admin_bih_citizen_path(@citizen)
        end

        # POST /admin/bih/citizens/:id/unlink-viber
        # Correction action: detach the Viber linkage from this user. We only
        # clear the user association (decidim_user_id) — the linkage row itself
        # remains as a phone-proof artefact (a valid phone-only linkage). This is
        # never used to mutate the account or session; it only stops goodwill
        # attribution flowing to the wrong user.
        def unlink_viber
          @citizen = find_citizen!
          return unless @citizen

          linkage = viber_linkage_for(@citizen)
          if linkage.nil?
            flash[:alert] = t(".no_linkage")
          else
            # update_column(s): we deliberately bypass validations/callbacks here.
            # Clearing only decidim_user_id can leave a row that is phone-present
            # (valid) or, for a Viber-link-only row, phone-nil — and the latter
            # would fail the phone_required? validation on a normal save even
            # though "detached" is a legitimate intermediate state for an admin
            # correction. We persist exactly the one column we mean to change.
            # rubocop:disable Rails/SkipsModelValidations -- intentional: a
            # detached linkage can be a phone-nil/user-nil shape that the
            # phone_required? validation rejects on save, yet "detached" is a
            # legitimate admin-correction state. We persist only decidim_user_id.
            linkage.update_columns(decidim_user_id: nil, updated_at: Time.current)
            # rubocop:enable Rails/SkipsModelValidations
            audit_operator_action!(
              "citizen_viber_unlinked",
              permission: "citizen_identity_correction",
              resource: @citizen,
              metadata: { linkage_id: linkage.id }
            )
            flash[:notice] = t(".unlinked")
          end
          redirect_to admin_bih_citizen_path(@citizen)
        end

        # POST /admin/bih/citizens/:id/clear-komsiluk
        # Correction action: reset the citizen's komšiluk/MZ assignment so they
        # can re-pick (e.g. an erroneous dropdown choice). The profile row is
        # kept (lazy-created elsewhere); only the assignment fields are cleared.
        def clear_komsiluk
          @citizen = find_citizen!
          return unless @citizen

          profile = citizen_profile_for(@citizen)
          if profile.nil? || !profile.assigned?
            flash[:alert] = t(".no_komsiluk")
          else
            profile.update!(komsiluk_id: nil, mz_id: nil, source: nil, assigned_at: nil)
            audit_operator_action!(
              "citizen_komsiluk_cleared",
              permission: "citizen_identity_correction",
              resource: @citizen,
              metadata: { profile_id: profile.id }
            )
            flash[:notice] = t(".komsiluk_cleared")
          end
          redirect_to admin_bih_citizen_path(@citizen)
        end

        # POST /admin/bih/citizens/:id/reverse/:transaction_id
        # Reverse a mistaken/abusive ORIGINAL ledger entry from this citizen's
        # profile. Posts an append-only mirror "adjustment" via Ledger#reverse;
        # never edits/deletes the original (the ledger is immutable). Mirrors the
        # dashboard's GoodwillController#reverse_transaction guards:
        #   * org-scoped lookup of BOTH the citizen and the transaction;
        #   * only an ORIGINAL non-adjustment transaction is reversible (refuse a
        #     reversal/adjustment, and refuse a second reverse of the same txn);
        #   * already-reversed is handled gracefully (the idempotency unique index
        #     raises RecordNotUnique on a concurrent double-reverse).
        def reverse_transaction
          @citizen = find_citizen!
          return unless valid_reversal_request?

          txn = find_citizen_transaction(@citizen, params[:transaction_id])

          if txn.nil?
            flash[:alert] = t(".reverse_failed", default: "Reversal failed.")
          elsif txn.kind == "adjustment" || txn.reversing? || already_reversed?(txn)
            # Don't reverse a reversal/adjustment, and don't reverse the same txn
            # twice (a double-click would otherwise post another mirror debit).
            flash[:alert] = t(".already_reversed", default: "This transaction is an adjustment or has already been reversed.")
          else
            Decidim::Bih::Goodwill::Transaction.transaction do
              reversal = Decidim::Bih::Goodwill::AwardDispatch.reverse_transaction(txn, actor: current_user)
              audit_operator_action!(
                "citizen_transaction_reversed",
                permission: "goodwill_reverse_transaction",
                resource: txn,
                metadata: {
                  citizen_id: @citizen.id,
                  reversal_transaction_id: reversal&.id,
                  **private_action_reason.metadata
                }
              )
            end
            pending_recovery = Decidim::Bih::Goodwill::CreditCorrection.where(original_transaction_id: txn.id).order(id: :desc).first&.settlement&.status == "admin_pending"
            flash[:notice] = t(".reversed", default: "Transaction reversed (a mirror adjustment was posted).")
            flash[:notice] = t("decidim.bih.admin.goodwill_corrections.statuses.admin_pending") if pending_recovery
          end
          redirect_to admin_bih_citizen_path(@citizen)
        rescue ActiveRecord::RecordNotUnique
          # Lost a concurrent double-reverse race; the reversal already exists.
          flash[:alert] = t(".already_reversed", default: "This transaction is an adjustment or has already been reversed.")
          redirect_to admin_bih_citizen_path(@citizen)
        rescue StandardError => e
          Rails.logger.error("[Admin::Citizens] reverse failed for txn #{params[:transaction_id]} (citizen #{@citizen&.id}): #{e.class}: #{e.message}")
          flash[:alert] = t(".reverse_failed", default: "Reversal failed.")
          redirect_to admin_bih_citizen_path(@citizen)
        end

        private

        def private_action_reason
          @private_action_reason ||= Decidim::Bih::Admin::PrivateActionReason.new(params[:private_reason])
        end

        def valid_reversal_request?
          return false unless @citizen
          return true if private_action_reason.valid?

          flash[:alert] = private_action_reason_error
          redirect_to admin_bih_citizen_path(@citizen)
          false
        end

        def private_action_reason_error
          t(
            "decidim.bih.admin.private_action_reason.invalid",
            count: Decidim::Bih::Admin::PrivateActionReason::MAX_LENGTH,
            default: "Enter a private operator reason (1–%{count} characters)."
          )
        end

        def load_ledger_context(citizen)
          @account = citizen_account(citizen)
          @level = Decidim::Bih::Goodwill::Levels.for(@account&.contribution_score.to_i)
          @ledger_entries = recent_ledger_entries(citizen)
          @reversed_transaction_ids = reversed_transaction_ids(@ledger_entries)
          @open_fulfillments = open_fulfillments(citizen)
          @referrals = referrals_for(citizen)
        end

        def load_identity_context(citizen)
          @viber_linkage = viber_linkage_for(citizen)
          @viber_business_contact = viber_business_contact_for(citizen)
          @citizen_profile = citizen_profile_for(citizen)
        end

        def find_citizen!
          find_scoped!(
            Decidim::User
              .where(organization: current_organization, deleted_at: nil)
              .not_user_group,
            id: params[:id],
            redirect_to: admin_bih_citizens_path,
            flash_key: "decidim.bih.admin.citizens.show.not_found"
          )
        end

        def search_users(query)
          q = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
          Decidim::User
            .where(organization: current_organization, deleted_at: nil)
            .not_user_group
            .where("name ILIKE :q OR nickname ILIKE :q OR email ILIKE :q", q:)
            .order(:name)
            .limit(20)
        end

        # Read-only account lookup — never create-on-GET.
        def citizen_account(citizen)
          Decidim::Bih::Goodwill::Account.find_by(
            organization: current_organization,
            owner_type: citizen.class.base_class.name,
            owner_id: citizen.id
          )
        end

        def recent_ledger_entries(citizen)
          account = citizen_account(citizen)
          return [] unless account

          account.entries
                 .includes(:ledger_transaction)
                 .order(created_at: :desc, id: :desc)
                 .page(params[:ledger_page]).per(LEDGER_HISTORY_LIMIT)
        end

        # Current source targets decide whether earns can be revoked again.
        # Wallet-only transfers retain their immutable reversal-key check.
        def reversed_transaction_ids(entries)
          transactions = entries.map(&:ledger_transaction).uniq(&:id)
          return Set.new if transactions.empty?

          recognized = Decidim::Bih::Goodwill::SourceCreditCorrection.recognized_totals(transactions)
          revoked = recognized.select { |_id, target| target <= 0 }.keys.to_set
          keys = transactions.reject { |txn| txn.kind == "earn" }.map { |txn| "reversal_of:#{txn.id}" }
          legacy = Decidim::Bih::Goodwill::Transaction
            .where(organization: current_organization, idempotency_key: keys)
            .pluck(:idempotency_key)
            .to_set { |key| key.delete_prefix("reversal_of:").to_i }
          revoked | legacy
        end

        def open_fulfillments(citizen)
          Decidim::Bih::Goodwill::RewardFulfillment
            .open
            .where(organization: current_organization, decidim_user_id: citizen.id)
            .order(created_at: :desc)
        end

        def referrals_for(citizen)
          Decidim::Bih::Goodwill::Referral
            .where(organization: current_organization, referrer_id: citizen.id)
            .order(created_at: :desc)
            .limit(10)
        end

        # Find a transaction that (a) belongs to this organization AND (b) touches
        # THIS citizen's account, so an operator on one citizen's profile can only
        # reverse that citizen's own entries — never a cross-org row and never
        # another citizen's transaction. Returns nil when no such txn exists (the
        # caller turns that into a friendly "reverse_failed" flash + redirect).
        def find_citizen_transaction(citizen, transaction_id)
          account = citizen_account(citizen)
          return nil unless account

          Decidim::Bih::Goodwill::Transaction
            .where(organization: current_organization, id: transaction_id)
            .where(
              "EXISTS (SELECT 1 FROM decidim_bih_goodwill_entries e " \
              "WHERE e.decidim_bih_goodwill_transaction_id = decidim_bih_goodwill_transactions.id " \
              "AND e.decidim_bih_goodwill_account_id = ?)",
              account.id
            )
            .first
        end

        # True when a reversing transaction for +txn+ already exists in this org
        # (its per-org unique idempotency key is "reversal_of:<id>"). Mirrors the
        # dashboard guard so a double-reverse is a no-op rather than a second debit.
        def already_reversed?(txn)
          if txn.kind == "earn"
            return Decidim::Bih::Goodwill::SourceCreditCorrection.recognized_total(txn) <= 0
          end

          Decidim::Bih::Goodwill::Transaction
            .exists?(organization: current_organization, idempotency_key: "reversal_of:#{txn.id}")
        end

        # Org-scoped Viber linkage for this citizen (or nil). Never returns a
        # cross-org row — the lookup is constrained to current_organization.
        def viber_linkage_for(citizen)
          Decidim::Bih::Viber::Linkage.find_by(
            organization: current_organization,
            decidim_user_id: citizen.id
          )
        end

        # Org-scoped Viber Business Messages delivery address for this citizen
        # (or nil), same org-constrained lookup as the linkage above. This is
        # the Bot-free record written when a phone is proven through SMS
        # verification, and it is what proactive Viber notices actually address.
        def viber_business_contact_for(citizen)
          Decidim::Bih::Viber::BusinessContact.find_by(
            organization: current_organization,
            decidim_user_id: citizen.id
          )
        end

        # Org-scoped komšiluk profile for this citizen (or nil). Read-only here:
        # we do NOT lazy-create on a GET (CitizenProfile.for_user would create a
        # bare row), so an unassigned citizen shows "no komšiluk" cleanly.
        def citizen_profile_for(citizen)
          Decidim::Bih::CitizenProfile.find_by(
            organization: current_organization,
            decidim_user_id: citizen.id
          )
        end
      end
    end
  end
end
