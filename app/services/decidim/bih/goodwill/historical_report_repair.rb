# frozen_string_literal: true
require "digest"
require "json"

module Decidim
  module Bih
    module Goodwill
      # Private bounded outcome-only repair. The manifest is reviewed evidence,
      # not an instruction to discover and correct additional reports at apply.
      class HistoricalReportRepair
        class Invalid < StandardError; end
        RULE = "report-outcome-v1:ordinary20:duplicate5:rejected0:anonymous-unchanged".freeze
        MAX_SOURCES = 100
        def initialize(organization:)
          @organization = organization
        end

        def preview(report_ids:)
          reports = sources(report_ids)
          build_manifest(reports)
        end

        def apply!(manifest:, actor:, expected_digest:, expected_summary:)
          authorize!(actor)
          data = manifest.deep_stringify_keys
          validate_manifest!(data, expected_digest, expected_summary)
          reports = sources(data.fetch("rows").map { |row| row.fetch("report_id") })
          accounts = data.fetch("accounts").map { |row| Account.find_by!(id: row.fetch("account_id"), organization: @organization) }
          result = nil
          Account.transaction(requires_new: true) do
            AccountLocks.with(accounts) do
              # Parents and linked reports can change the effective outcome. Lock
              # their current connected family before validating the whole batch.
              family_ids = reports.flat_map { |report| ReportEntitlement.family_ids(report) }.uniq.sort
              Report.where(organization: @organization, id: family_ids).order(:id).lock.load
              reports.each(&:reload)
              previous = applied_journals(data)
              if previous.any?
                raise Invalid, "partial or superseded repair; review required" unless replay_valid?(data, previous, reports)
                result = { replay: true, corrections: previous.size, recognition_delta: 0, wallet_delta: 0 }
                next
              end
              current = build_manifest(reports)
              %w(rule organization_id rows accounts summary).each do |field|
                raise Invalid, "stale #{field}; generate a new manifest" unless current.fetch(field) == data.fetch(field)
              end
              corrections = reports.map do |report|
                row = data.fetch("rows").find { |candidate| candidate.fetch("report_id") == report.id }
                SourceCreditCorrection.call(report:, actor:, expected_version: row.fetch("decision_version"), reason: reason(data))
              end
              raise Invalid, "missing correction; transaction rolled back" unless corrections.all?
              verify_result!(data, corrections)
              result = { replay: false, corrections: corrections.size,
                recognition_delta: corrections.sum(&:recognition_delta),
                wallet_delta: corrections.sum { |correction| correction.settlement.status == "settled" ? correction.settlement.wallet_delta : 0 },
                admin_pending: corrections.count { |correction| correction.settlement.status == "admin_pending" }, digest: data.fetch("digest") }
            end
          end
          result
        end

        def self.digest(data)
          Digest::SHA256.hexdigest(JSON.generate(canonical(data.except("digest"))))
        end

        def self.canonical(value)
          case value
          when Hash then value.stringify_keys.sort.to_h.transform_values { |item| canonical(item) }
          when Array then value.map { |item| canonical(item) }
          else value.as_json
          end
        end

        private

        def authorize!(actor)
          raise Decidim::ActionForbidden unless actor && actor.organization == @organization &&
            OperatorAuthorization.allowed?(actor, :goodwill_reverse_transaction, organization: @organization)
        end

        def sources(ids)
          ids = Array(ids).map { |id| Integer(id) }.uniq.sort
          raise Invalid, "select 1..#{MAX_SOURCES} explicit report IDs" unless ids.size.between?(1, MAX_SOURCES)
          rows = Report.where(organization: @organization, id: ids).order(:id).to_a
          raise Invalid, "source missing or tenant mismatch" unless rows.map(&:id) == ids
          rows
        end

        def original_for(report)
          Transaction.find_by!(organization: @organization, kind: "earn", idempotency_key: IdempotencyKey.report(report.id))
        end

        def build_manifest(reports)
          rows = reports.map do |report|
            original = original_for(report)
            account = SourceCreditCorrection.credited_account(original)
            state = SourceCreditCorrection.preview(report:).stringify_keys
            outcome = ReportEntitlement.outcome_target(report)
            raise Invalid, "scope contains ordinary report #{report.id}" unless report.status == "odbijeno" || report.duplicate_of_report_id.present?
            raise Invalid, "entitlement policy would broaden historical scope" unless state.fetch("target_amount") == outcome
            raise Invalid, "scope must contain an outstanding downward outcome correction" unless state.fetch("recognition_delta").negative?
            earned_at = SourceCreditCorrection.earning_time(original).in_time_zone("Europe/Sarajevo")
            state.except("wallet_before", "wallet_after", "status", "level_before", "level_after").merge(
              "settlement_status" => state.fetch("status"),
              "report_id" => report.id, "original_transaction_id" => original.id, "account_id" => account.id,
              "owner_id" => account.owner_id, "status" => report.status, "duplicate_of" => report.duplicate_of_report_id,
              "source_updated_at" => report.updated_at.iso8601(6), "source_wallet_total" => SourceCreditCorrection.wallet_total(original),
              "prior_adjustments" => legacy_adjustments(original, account),
              "prior_correction_ids" => CreditCorrection.where(original_transaction_id: original.id).order(:id).pluck(:id),
              "earned_at" => earned_at.iso8601(6), "month" => earned_at.strftime("%Y-%m"), "week" => earned_at.beginning_of_week.to_date.iso8601,
              "receipt" => { "reference" => report.reference, "reason" => outcome.zero? ? "rejected_report" : "duplicate_report",
                             "old_total" => state.fetch("previous_target"), "new_total" => outcome,
                             "correction" => state.fetch("recognition_delta") }
            )
          end
          accounts = rows.group_by { |row| row.fetch("account_id") }.sort.map do |account_id, source_rows|
            account = Account.find_by!(id: account_id, organization: @organization)
            wallet = account.recomputed_balance
            contribution = account.recomputed_contribution
            raise Invalid, "account projection drift #{account.id}" unless account.cached_balance == wallet && account.cached_contribution == contribution
            wallet_due = source_rows.sum { |row| row.fetch("wallet_delta") }
            projected_wallet = wallet
            pending = false
            source_rows.each do |row|
              delta = row.fetch("wallet_delta")
              if projected_wallet + delta < 0 || (delta.negative? && row.fetch("settlement_status") == "admin_pending")
                pending = true
              else
                projected_wallet += delta
              end
            end
            wallet_delta = projected_wallet - wallet
            recognition_delta = source_rows.sum { |row| row.fetch("recognition_delta") }
            { "account_id" => account.id, "owner_id" => account.owner_id, "wallet_before" => wallet,
              "wallet_delta" => wallet_delta, "wallet_due" => wallet_due, "wallet_after" => projected_wallet,
              "recognition_before" => contribution, "recognition_delta" => recognition_delta,
              "recognition_after" => contribution + recognition_delta,
              "level_before" => Levels.for(contribution).key.to_s, "level_after" => Levels.for(contribution + recognition_delta).key.to_s,
              "status" => pending ? "admin_pending" : "settled" }
          end
          data = { "version" => 1, "rule" => RULE, "organization_id" => @organization.id,
            "generated_at" => Time.current.iso8601(6), "rows" => rows, "accounts" => accounts,
            "summary" => { "reports" => rows.size, "users" => accounts.size,
              "recognition_delta" => rows.sum { |row| row.fetch("recognition_delta") },
              "wallet_delta" => accounts.sum { |row| row.fetch("wallet_delta") },
              "wallet_due" => accounts.sum { |row| row.fetch("wallet_due") },
              "minimum_wallet_after" => accounts.map { |row| row.fetch("wallet_after") }.min,
              "admin_pending" => accounts.count { |row| row.fetch("status") == "admin_pending" } } }
          data.merge("digest" => self.class.digest(data))
        end

        def legacy_adjustments(original, account)
          Transaction.where(organization: @organization, kind: "adjustment")
            .where("metadata->>'reverses_transaction_id' = ? OR reason = ?", original.id.to_s, "reversal_of:#{original.id}")
            .joins(:entries).where(decidim_bih_goodwill_entries: { decidim_bih_goodwill_account_id: account.id })
            .order(:id).pluck("decidim_bih_goodwill_transactions.id", :reason, "decidim_bih_goodwill_entries.amount")
        end

        def validate_manifest!(data, expected_digest, expected_summary)
          raise Invalid, "manifest digest mismatch" unless data["digest"] == expected_digest && expected_digest == self.class.digest(data)
          raise Invalid, "manifest tenant/rule mismatch" unless data["organization_id"] == @organization.id && data["rule"] == RULE && data["version"] == 1
          expected_summary.stringify_keys.each do |key, value|
            raise Invalid, "approved scope changed: #{key}" unless data.fetch("summary").fetch(key) == value
          end
          raise Invalid, "explicit expected counts and delta required" unless %w(reports users recognition_delta).all? { |key| expected_summary.stringify_keys.key?(key) }
        end

        def reason(data) = "historical_report_outcome:#{data.fetch('digest')}"
        def applied_journals(data)
          CreditCorrection.where(organization: @organization, reason: reason(data)).order(:id).to_a
        end

        def replay_valid?(data, journals, reports)
          return false unless journals.size == reports.size
          reports.all? do |report|
            row = data.fetch("rows").find { |candidate| candidate.fetch("report_id") == report.id }
            journal = journals.find { |entry| entry.original_transaction_id == row.fetch("original_transaction_id") }
            original = original_for(report)
            journal && journal.decision_version == SourceCreditCorrection.version_for(report) &&
              journal.target_amount == SourceCreditCorrection.target_for(report) &&
              journal.id == CreditCorrection.where(original_transaction_id: original.id).maximum(:id) &&
              SourceCreditCorrection.recognized_total(original) == journal.target_amount
          end
        end

        def verify_result!(data, corrections)
          corrections.each do |correction|
            raise Invalid, "recognition reconciliation failed" unless SourceCreditCorrection.recognized_total(correction.original_transaction) == correction.target_amount
            if correction.settlement.status == "settled"
              raise Invalid, "wallet source reconciliation failed" unless SourceCreditCorrection.wallet_total(correction.original_transaction) == correction.target_amount
            end
          end
          data.fetch("accounts").each do |row|
            account = Account.find(row.fetch("account_id"))
            raise Invalid, "negative wallet" if account.balance.negative?
            raise Invalid, "wallet reconciliation failed" unless account.cached_balance == account.recomputed_balance && account.cached_balance == row.fetch("wallet_after")
            raise Invalid, "recognition reconciliation failed" unless account.cached_contribution == account.recomputed_contribution && account.cached_contribution == row.fetch("recognition_after")
          end
        end
      end
    end
  end
end
