# frozen_string_literal: true
module Decidim
  module Bih
    module Goodwill
      # Recognition and recovery deliberately have separate immutable evidence.
      # A pending wallet recovery never leaves invalid contribution on a board.
      class SourceCreditCorrection
        class StaleDecision < StandardError; end
        class << self
          def call(report:, actor: nil, expected_version: nil, reason: nil)
            original = Transaction.find_by(organization: report.organization, idempotency_key: IdempotencyKey.report(report.id), kind: "earn")
            return unless original

            correct(original:, target: -> { target_for(report.reload, original:) }, version: -> { version_for(report.reload) },
                    actor:, expected_version:, reason: reason || "report_outcome", source_lock: report)
          end

          def for_corroboration(corroboration, actor: nil)
            original = Transaction.find_by(organization: corroboration.organization, idempotency_key: "report-corroboration:#{corroboration.id}", kind: "earn")
            return unless original

            report = corroboration.report
            correct(original:, target: -> { corroboration_target(corroboration, original:) },
                    version: -> { corroboration_version(corroboration, original:) }, actor:, reason: "corroboration_outcome", source_lock: report)
          end

          def corroboration_target(corroboration, original:)
            report = corroboration.report.reload
            ReportEntitlement.outcome_target(ReportEntitlement.root(report)).positive? &&
              ReportEntitlement.available?(report, account: credited_account(original), source_key: original.idempotency_key,
                                            occurred_at: earning_time(original)) ? ReportEntitlement::DUPLICATE_POINTS : 0
          end

          def corroboration_version(corroboration, original:)
            "#{version_for(corroboration.report.reload)}:corroboration:#{corroboration.id}:points:#{corroboration_target(corroboration, original:)}"
          end

          def target_for(report, original: nil)
            original ||= Transaction.find_by(organization: report.organization, idempotency_key: IdempotencyKey.report(report.id), kind: "earn")
            return ReportEntitlement.outcome_target(report) unless original
            ReportEntitlement.target(report, account: credited_account(original), source_key: original.idempotency_key, occurred_at: earning_time(original))
          end

          def outcome_version_for(report)
            event_id = report.events.where(event_type: %w(case_decision_applied duplicate_marked duplicate_cleared status_changed
                                                         case_second_reminder_closed)).maximum(:id)
            root = ReportEntitlement.root(report)
            root_event = root.events.where(event_type: %w(case_decision_applied duplicate_marked duplicate_cleared status_changed)).maximum(:id)
            "report:#{report.id}:#{event_id || 0}:#{report.status}:#{report.duplicate_of_report_id || 0}:root:#{root.id}:#{root.status}:#{root_event || 0}"
          end

          # Bind correction replay and previews to the effective target/rule too.
          # A cap candidate or settings change must not replay an obsolete target.
          def version_for(report)
            policy = Setting.where(organization: report.organization, namespace: EarningRules::SCHEDULE_NAMESPACE, key: "report").maximum(:updated_at)
            "#{outcome_version_for(report)}:points:#{target_for(report)}:policy:#{policy&.iso8601(6) || 'default'}"
          end

          def preview(report:)
            original = Transaction.find_by(organization: report.organization, idempotency_key: IdempotencyKey.report(report.id), kind: "earn")
            return unless original

            account = credited_account(original)
            previous = recognized_total(original)
            target = target_for(report)
            due = target - wallet_total(original)
            pending = CreditSettlement.joins(:credit_correction)
              .where(decidim_bih_goodwill_credit_corrections: { original_transaction_id: original.id }, status: %w(pending admin_pending)).exists?
            pending_recovery = due + account.balance < 0 || (pending && due.negative?)
            { source_key: original.idempotency_key, decision_version: version_for(report), previous_target: previous,
              target_amount: target, recognition_delta: target - previous, wallet_delta: due,
              wallet_before: account.balance, wallet_after: due + account.balance,
              status: pending_recovery ? "admin_pending" : "settled",
              level_before: Levels.for(account.contribution_score).key,
              level_after: Levels.for(account.contribution_score + target - previous).key }
          end

          def revoke(original, actor: nil, decision_version: nil)
            raise ArgumentError, "only original earns can be revoked" unless original.kind == "earn"
            report = source_report(original)
            version = -> { decision_version || "manual-revocation:#{source_state_version(original)}" }
            correct(original:, target: -> { 0 }, version:, actor:, reason: "earn_revocation", source_lock: report)
          end

          def source_report(original)
            if original.idempotency_key.to_s.start_with?("bih_report:")
              Report.find_by!(organization: original.organization, id: original.idempotency_key.delete_prefix("bih_report:"))
            elsif original.idempotency_key.to_s.start_with?("report-corroboration:")
              ReportCorroboration.find_by!(organization: original.organization, id: original.idempotency_key.delete_prefix("report-corroboration:")).report
            end
          end

          def source_state_version(original)
            report = source_report(original)
            return version_for(report.reload) if report
            CreditCorrection.where(original_transaction_id: original.id).where.not(reason: "earn_revocation").order(:id).last&.decision_version || "original:#{original.id}"
          end

          def settle!(correction, actor:)
            unless actor && actor.organization == correction.organization &&
                   Decidim::Bih::OperatorAuthorization.allowed?(actor, :goodwill_reverse_transaction, organization: correction.organization)
              raise Decidim::ActionForbidden
            end
            AccountLocks.with(correction.account) do
              current = CreditCorrection.where(original_transaction_id: correction.original_transaction_id).order(:id).last
              raise StaleDecision, "source correction was superseded" unless current&.id == correction.id

              original = correction.original_transaction
              report = source_report(original)
              report&.lock!
              if correction.reason == "earn_revocation"
                expected = "manual-revocation:#{source_state_version(original)}"
                raise StaleDecision, "source outcome changed" unless correction.decision_version == expected
              elsif report
                expected_version = version_for(report)
                expected_target = if correction.source_key.start_with?("report-corroboration:")
                  record = ReportCorroboration.find(correction.source_key.delete_prefix("report-corroboration:"))
                  expected_version = corroboration_version(record, original:)
                  corroboration_target(record, original:)
                else
                  target_for(report, original:)
                end
                unless expected_version == correction.decision_version && expected_target == correction.target_amount
                  raise StaleDecision, "report outcome changed"
                end
              end
              settle_locked(correction, actor:)
            end
          end

          def correct(original:, target:, version:, actor:, reason:, expected_version: nil, source_lock: nil)
            account = credited_account(original)
            raise ArgumentError, "correction actor tenant mismatch" if actor && actor.organization != original.organization
            AccountLocks.with(account) do
              source_lock&.lock!
              current_version = version.call.to_s
              raise StaleDecision, "source changed since preview" if expected_version && expected_version != current_version
              existing = CreditCorrection.find_by(organization: original.organization, source_key: source_key(original), decision_version: current_version)
              next existing if existing

              previous = recognized_total(original)
              desired = Integer(target.call)
              pending = CreditSettlement.joins(:credit_correction)
                .where(decidim_bih_goodwill_credit_corrections: { original_transaction_id: original.id }, status: %w(pending admin_pending)).exists?
              next if previous == desired && !pending

              correction = CreditCorrection.create!(organization: original.organization, account:, original_transaction: original,
                source_key: source_key(original), decision_version: current_version, previous_target: previous, target_amount: desired,
                recognition_delta: desired - previous, earned_at: earning_time(original), actor:, reason:,
                metadata: { level_before: Levels.for(account.reload.contribution_score).key,
                            level_after: Levels.for(account.contribution_score + desired - previous).key })
              CreditSettlement.joins(:credit_correction).where(decidim_bih_goodwill_credit_corrections: { original_transaction_id: original.id })
                              .where(status: %w(pending admin_pending)).update_all(status: "superseded", updated_at: Time.current)
              correction.create_settlement!(status: "pending")
              settle_locked(correction, actor:, allow_recovery: !pending)
              ContributionProjection.refresh!(account)
              ActiveRecord.after_all_transactions_commit do
                SourceCreditCorrectionNoticeJob.perform_later(correction.id)
              rescue StandardError => error
                Rails.logger.error("[goodwill] correction receipt enqueue failed: #{error.class}")
              end
              correction
            end
          end

          def settle_locked(correction, actor:, allow_recovery: true)
            settlement = correction.settlement
            return settlement if %w(settled superseded).include?(settlement.status)

            account = correction.account.reload
            delta = correction.target_amount - wallet_total(correction.original_transaction)
            if account.balance + delta < 0 || (!allow_recovery && delta.negative?)
              settlement.update!(status: "admin_pending", wallet_delta: delta)
              return settlement
            end
            transaction = if delta != 0
              Ledger.new.post(organization: correction.organization, kind: "adjustment", reason: "source_wallet_correction",
                idempotency_key: "source-correction:#{correction.id}",
                metadata: { source_key: correction.source_key, credit_correction_id: correction.id },
                entries: [{ account:, amount: delta }, { account: Ledger.new.system_account_for(correction.organization), amount: -delta }])
            end
            was_pending = settlement.status == "admin_pending"
            attributes = { status: "settled", wallet_delta: delta, ledger_transaction: transaction, settled_by: actor }
            attributes[:notified_at] = nil if was_pending
            settlement.update!(attributes)
            if was_pending
              ActiveRecord.after_all_transactions_commit do
                SourceCreditCorrectionNoticeJob.perform_later(correction.id)
              rescue StandardError => error
                Rails.logger.error("[goodwill] wallet recovery receipt enqueue failed: #{error.class}")
              end
            end
            settlement
          end

          # Batched current source targets for admin history. A pending wallet
          # recovery still contributes its signed recognition delta; an old zero
          # target does not block a later restored source from being revoked.
          def recognized_totals(originals)
            ids = originals.select { |original| original.kind == "earn" }.map(&:id).uniq
            return {} if ids.empty?

            source_ids = ids.map { |id| Account.connection.quote(id.to_s) }.join(",")
            query = <<~SQL
              SELECT recognition.source_key, SUM(recognition.amount)
              FROM (#{ContributionProjection.sql}) recognition
              JOIN decidim_bih_goodwill_accounts accounts ON accounts.id=recognition.account_id
              WHERE accounts.kind='user' AND recognition.source_key IN (#{source_ids})
              GROUP BY recognition.source_key
            SQL
            Account.connection.select_rows(query).to_h { |source_key, amount| [source_key.to_i, amount.to_i] }
          end

          def recognized_total(original)
            original.credited_amount + legacy_delta(original, contribution: true) + CreditCorrection.where(original_transaction_id: original.id).sum(:recognition_delta)
          end

          def wallet_total(original)
            original.credited_amount + legacy_delta(original, contribution: false) + CreditSettlement.joins(:credit_correction)
              .where(decidim_bih_goodwill_credit_corrections: { original_transaction_id: original.id }, status: "settled").sum(:wallet_delta)
          end

          def legacy_delta(original, contribution:)
            rows = Transaction.where(organization: original.organization, kind: "adjustment")
              .where("metadata->>'reverses_transaction_id' = ? OR reason = ?", original.id.to_s, "reversal_of:#{original.id}")
            rows = rows.where(reason: Transaction::CONTRIBUTION_ADJUSTMENT_REASONS) if contribution
            rows.joins(:entries).where(decidim_bih_goodwill_entries: { decidim_bih_goodwill_account_id: credited_account(original).id })
              .sum("decidim_bih_goodwill_entries.amount")
          end

          def credited_account(original)
            original.entries.find_by!("amount > 0").account
          end

          def source_key(original)
            original.idempotency_key.presence || "transaction:#{original.id}"
          end

          def earning_time(original)
            value = original.metadata.to_h["occurred_at"]
            value.present? ? Time.iso8601(value) : original.created_at
          end
        end
      end
    end
  end
end
