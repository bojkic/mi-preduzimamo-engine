# frozen_string_literal: true

require "pathname"

module Decidim
  module Bih
    module Admin
      # Read-only operator summary for the privacy retention sweep.
      #
      # It deliberately calls RetentionSweep in dry-run mode and parses only the
      # structured wrapper log lines, never raw report/contact/content data.
      class RetentionSummary
        POLICY_MONTHS = 36
        LOGIN_TOKEN_RETENTION_DAYS = 60
        DEFAULT_LOG_PATH = "shared/log/privacy-retention-sweep.log"
        HISTORY_LIMIT = 10
        # Derived from the privacy audit contracts so a bucket cannot exist in
        # the sweep but be missing from this dashboard (or the reverse). Adding
        # a bucket to PrivacyAuditContracts with a service_cutoff_key is the
        # only step needed to surface it here.
        COUNT_KEYS = Decidim::Bih::PrivacyAuditContracts.sweep_bucket_ids
        # bucket id => the cutoff key its run recorded, from the same contract
        # source, so a persisted run's cutoff can always be resolved for display.
        CUTOFF_KEYS = Decidim::Bih::PrivacyAuditContracts.sweep_buckets.to_h do |bucket|
          [bucket.fetch(:id).to_sym, bucket.fetch(:service_cutoff_key)]
        end.freeze

        def initialize(organization:, cutoff_on: nil, log_path: nil)
          @organization = organization
          @cutoff_on = normalize_date(cutoff_on || (Date.current << POLICY_MONTHS))
          @log_path = Pathname.new(log_path || Rails.root.join(ENV.fetch("PRIVACY_RETENTION_LOG", DEFAULT_LOG_PATH)))
        end

        def summary
          {
            organization: organization,
            cutoff_on: cutoff_on.iso8601,
            policy_months: POLICY_MONTHS,
            status: current_status,
            total: current_total,
            scope_key: retention_scope_key,
            rows: rows,
            last_run: last_run,
            run_history: run_history
          }
        end

        private

        attr_reader :organization, :cutoff_on, :log_path

        def rows
          COUNT_KEYS.map do |key|
            {
              key: key.to_s,
              count: current_counts.fetch(key, 0),
              cutoff_on: cutoff_on_for(key).iso8601
            }
          end
        end

        def current_status
          return "fail" unless organization
          return "warn" if current_total.positive?

          "ok"
        rescue StandardError
          "fail"
        end

        def current_total
          current_counts.values.sum
        end

        def current_counts
          return @current_counts if defined?(@current_counts)

          @current_counts = organization ? retention_counts : COUNT_KEYS.index_with { 0 }
        end

        def retention_counts
          result = Decidim::Bih::Privacy::RetentionSweep.call(**retention_attributes, dry_run: true)
          COUNT_KEYS.index_with { |key| result.counts.fetch(key, 0).to_i }
        end

        def retention_scope_key
          Decidim::Bih::Privacy::RetentionSweep.scope_key(**retention_attributes)
        end

        # Every sweep bucket gets the policy cutoff, derived from the same
        # contract list as COUNT_KEYS. Only the genuine exceptions are stated:
        # login tokens keep a much shorter operational window, and coordinate
        # rounding is a precision setting rather than a cutoff.
        def retention_attributes
          cutoffs = Decidim::Bih::PrivacyAuditContracts.sweep_cutoff_keys.index_with { cutoff_on }

          cutoffs.merge(
            organization: organization,
            report_coordinate_precision: 2,
            login_token_before: login_token_cutoff_on
          )
        end

        def last_run
          persisted = latest_persisted_run
          return persisted if persisted

          return missing_log_status unless log_path.file?

          lines = log_path.readlines(chomp: true).last(1000)
          start_index = lines.rindex { |line| line.include?("privacy-retention-sweep START") }
          return missing_log_status unless start_index

          build_last_run(lines[start_index..])
        rescue StandardError => e
          failed_log_status(e)
        end

        def latest_persisted_run
          run = recent_retention_runs.find(&:live?)
          run_status(run) if run
        end

        def run_history
          recent_retention_runs.map { |run| run_status(run) }
        rescue StandardError
          []
        end

        def recent_retention_runs
          return [] unless organization

          @recent_retention_runs ||= Decidim::Bih::Privacy::RetentionRun
                                     .where(organization: organization)
                                     .recent
                                     .limit(HISTORY_LIMIT)
                                     .to_a
        end

        def run_status(run)
          {
            status: run.status,
            started_at: run.started_at&.utc&.iso8601,
            ended_at: run.finished_at&.utc&.iso8601,
            cutoff_on: cutoff_from_run(run),
            dry_run: run.dry_run?.to_s,
            apply: run.live?.to_s,
            total: run.total.to_s,
            counts: safe_run_counts(run),
            log_path: nil,
            detail: run_detail(run)
          }
        end

        def build_last_run(block)
          start_line = block.first
          end_line = block.find { |line| line.include?("privacy-retention-sweep END") }
          result_line = block.find { |line| line.start_with?("dry_run=") }
          counts = parse_counts(block)
          ended_at = timestamp_from(end_line)
          status = ended_at ? "ok" : "fail"
          status = "warn" if ended_at && result_line.blank?

          {
            status: status,
            started_at: timestamp_from(start_line)&.iso8601,
            ended_at: ended_at&.iso8601,
            cutoff_on: cutoff_from(start_line),
            dry_run: result_value(result_line, "dry_run"),
            apply: result_value(result_line, "apply"),
            total: result_value(result_line, "total"),
            counts: counts,
            log_path: log_path.to_s,
            detail: last_run_detail(status:, result_line:)
          }
        end

        def missing_log_status
          {
            status: "warn",
            started_at: nil,
            ended_at: nil,
            cutoff_on: nil,
            dry_run: nil,
            apply: nil,
            total: nil,
            counts: {},
            log_path: log_path.to_s,
            detail: "log missing"
          }
        end

        def failed_log_status(error)
          {
            status: "fail",
            started_at: nil,
            ended_at: nil,
            cutoff_on: nil,
            dry_run: nil,
            apply: nil,
            total: nil,
            counts: {},
            log_path: log_path.to_s,
            detail: sanitize("#{error.class}: #{error.message}")
          }
        end

        def parse_counts(lines)
          COUNT_KEYS.each_with_object({}) do |key, acc|
            line = lines.find { |candidate| candidate.match?(/\A#{Regexp.escape(key.to_s)}=\d+\z/) }
            acc[key.to_s] = line.to_s.split("=", 2).last.to_i if line
          end
        end

        def timestamp_from(line)
          return nil unless line

          match = line.match(/\A\[(?<timestamp>[^\]]+)\]/)
          Time.zone.parse(match[:timestamp]) if match
        end

        def cutoff_from(line)
          return nil unless line

          line[/cutoff=(\d{4}-\d{2}-\d{2})/, 1]
        end

        def result_value(line, key)
          return nil unless line

          line[/#{Regexp.escape(key)}=([^\s]+)/, 1]
        end

        def cutoff_from_run(run)
          values = COUNT_KEYS.filter_map do |key|
            value = run.cutoffs.to_h[CUTOFF_KEYS.fetch(key)]
            value.to_s[0, 10] if value.present?
          end.uniq

          return nil if values.empty?
          return values.first if values.one?

          "custom"
        end

        def safe_run_counts(run)
          COUNT_KEYS.each_with_object({}) do |key, acc|
            acc[key.to_s] = run.counts.to_h[key.to_s].to_i
          end
        end

        def run_detail(run)
          case run.status
          when "running" then "run still in progress"
          when "fail" then "failed; sanitized failure retained"
          else "structured history present"
          end
        end

        def last_run_detail(status:, result_line:)
          return "last run did not finish" if status == "fail"
          return "result summary missing" if result_line.blank?

          "structured summary present"
        end

        def normalize_date(value)
          case value
          when Date then value
          when Time, DateTime then value.to_date
          else Date.iso8601(value.to_s)
          end
        end

        def cutoff_on_for(key)
          key == :login_tokens ? login_token_cutoff_on : cutoff_on
        end

        def login_token_cutoff_on
          @login_token_cutoff_on ||= Date.current - LOGIN_TOKEN_RETENTION_DAYS
        end

        def sanitize(value)
          if defined?(Decidim::Bih::SafeErrorMetadata)
            Decidim::Bih::SafeErrorMetadata.sanitize_text(value, max: 240)
          else
            value.to_s.split.join(" ")[0, 240]
          end
        end
      end
    end
  end
end
