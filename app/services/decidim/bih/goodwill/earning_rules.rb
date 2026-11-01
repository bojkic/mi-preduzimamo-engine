# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # The earning policy: how many points each civic action is worth, plus
      # per-user daily or calendar-month allowances. Values default to
      # the agreed BiH schedule and are OVERRIDABLE by the host app via
      # Decidim::Bih.goodwill_earning_schedule / goodwill_daily_caps.
      #
      # Awarding takes a per-owner Postgres advisory lock so the cap check and the
      # ledger write are atomic even under concurrent background jobs.
      class EarningRules
        DEFAULT_SCHEDULE = {
          volunteer_hour: 100, # historical hour unit; kept for other hosts and old ledger entries
          volunteer_day: 100, # one confirmed Sarajevo work date per person
          volunteer_opportunity: 25, # prijedlog prilike, ne izvršenje
          proposal: 25, # teži i konstruktivniji od prijave
          referral: 25, # verifikovan poziv (pozvani se registruje + verifikuje)
          report: 20, # osnovna jedinica skale
          debate: 15, # otvaranje teme nije komentar
          contribution_offer: 15, # LFBN-priznata isporuka nenovčane ponude
          postal_verified: 40, # jednokratno; verifikacija adrese pismom
          komsiluk_selected: 10, # jednokratno; izbor komšiluka je jedan klik
          verification: 10, # jednokratna dobrodošlica na prvu verifikaciju
          volunteer_availability: 10, # izjava o dostupnosti, ne rad
          komsiluk_post: 10, # objava na komšiluk tabli
          budget_vote: 5, # participativni budžet je zastava platforme
          comment: 3, # jeftina radnja
          vote: 2, # jeftina radnja
          like: 1 # najjeftinija radnja
        }.freeze

        DEFAULT_DAILY_CAPS = {
          # Jeftine radnje — granica broja BODOVANIH radnji po danu (spec 2026-08-31).
          like: 10,
          vote: 10,
          comment: 5,
          # Limit rewarded actions while allowing further civic participation.
          report: 5,
          debate: 3,
          komsiluk_post: 3,
          budget_vote: 20
        }.freeze

        # Namespaces in the Decidim::Bih::Setting store this class reads.
        DEFAULT_MONTHLY_CAPS = { proposal: 1 }.freeze
        MONTHLY_CAPS_NAMESPACE = "goodwill_monthly_caps"
        POLICY_NAMESPACE = "goodwill_policy"

        SCHEDULE_NAMESPACE = "goodwill_schedule"
        CAPS_NAMESPACE = "goodwill_caps"
        SEASON_NAMESPACE = "goodwill_season"
        SEASON_KEY = "started_at"

        # Points for ONE action, for callers that want the number and nothing
        # else — a CTA hint, the invite nudge, a piece of explanatory copy.
        # Resolves through the same defaults → host config → per-org DB chain as
        # an award does, and falls back to the default rather than raising: a
        # missing database must not be the reason a page cannot render a
        # sentence. Awards keep going through #points_for on an instance.
        def self.points_for_action(action, organization: nil)
          new(organization:).points_for(action)
        rescue StandardError
          DEFAULT_SCHEDULE[action.to_sym].to_i
        end

        # `organization` (optional) enables DB-backed overrides:
        # DEFAULTS → host config → per-org Decidim::Bih::Setting (DB wins).
        # When nil — the legacy call shape used by GoodwillAwardJob et al — the
        # store is consulted lazily per-award using the owner's organization, so
        # the no-org public readers (points_for/cap_for/schedule) stay on
        # DEFAULTS → config exactly as before, while awards still honour DB
        # overrides. An EMPTY store is byte-identical to the pre-table behavior.
        def initialize(
          schedule: Decidim::Bih.goodwill_earning_schedule,
          daily_caps: Decidim::Bih.goodwill_daily_caps,
          ledger: Ledger.new,
          organization: nil
        )
          @config_schedule = DEFAULT_SCHEDULE.merge(symbolize(schedule))
          @config_daily_caps = DEFAULT_DAILY_CAPS.merge(symbolize(daily_caps))
          @organization = organization
          @schedule = merged_schedule(@organization)
          @daily_caps = merged_daily_caps(@organization)
          @monthly_caps = DEFAULT_MONTHLY_CAPS.merge(int_overrides(@organization, MONTHLY_CAPS_NAMESPACE))
          @ledger = ledger
        end

        # The effective points-per-action schedule (host + DB overrides merged
        # over the defaults). Read-only; surfaced by the public onboarding
        # explainer. Reflects DB overrides only when an organization was given.
        attr_reader :schedule, :monthly_caps

        # The public rules show the active work unit only. The inactive key
        # stays available for historical ledger rows and other hosts.
        def public_schedule
          inactive = Decidim::Bih.volunteer_work_award_unit.to_sym == :day ? :volunteer_hour : :volunteer_day
          @schedule.except(inactive)
        end

        def points_for(action)
          @schedule[action.to_sym].to_i
        end

        def cap_for(action)
          period_for(action) == "month" ? @monthly_caps[action.to_sym] : @daily_caps[action.to_sym]
        end

        def period_for(action)
          DEFAULT_MONTHLY_CAPS.key?(action.to_sym) ? "month" : "day"
        end

        def cap_period_for(action)
          period_for(action).to_sym
        end

        def next_reset_for(action, at: Time.current)
          local = at.in_time_zone("Europe/Sarajevo")
          period_for(action) == "month" ? local.beginning_of_month.next_month : local.next_day.beginning_of_day
        end

        def self.monthly_proposal_effective_at(organization)
          value = Decidim::Bih::Setting.namespace_for(organization, POLICY_NAMESPACE)["monthly_proposal_effective_at"]
          Time.iso8601(value.to_s) if value.present?
        rescue ArgumentError
          nil
        end

        # Award points for `action` performed by `owner`. Enforces its period cap
        # and idempotency. Returns the Transaction, or nil (capped / zero-value /
        # duplicate). The owner advisory lock serialises concurrent awards.
        def award(owner, action, idempotency_key: nil, metadata: {})
          action = action.to_sym
          metadata = (metadata || {}).stringify_keys
          return nil unless owner.respond_to?(:organization) && owner.organization
          return nil if owner.respond_to?(:group?) && owner.group?
          raise ArgumentError, "earning rules organization mismatch" if @organization && @organization != owner.organization

          schedule, daily_caps = effective_rules_for(owner.organization)
          amount = metadata["corroboration_id"] ? ReportEntitlement::DUPLICATE_POINTS : schedule[action].to_i
          validate_proposal_source!(owner, idempotency_key) if action == :proposal
          occurred_at = source_time(action, idempotency_key, metadata)
          period = period_for(action)
          effective_at = self.class.monthly_proposal_effective_at(owner.organization)
          period = "day" if action == :proposal && effective_at && occurred_at < effective_at
          zone_time = occurred_at.in_time_zone("Europe/Sarajevo")
          start_at = period == "month" ? zone_time.beginning_of_month : zone_time.beginning_of_day
          end_at = period == "month" ? start_at.next_month : start_at.next_day.beginning_of_day
          cap = if period == "month"
                  DEFAULT_MONTHLY_CAPS.merge(int_overrides(owner.organization, MONTHLY_CAPS_NAMESPACE))[action]
                elsif action == :proposal
                  5 # previously published daily rule, only before the recorded cutover
                else
                  daily_caps[action]
                end
          result = nil
          capped_now = false
          account = ledger.account_for(owner)
          AccountLocks.with(account) do
            source_key = idempotency_key.presence || "action:#{action}:#{SecureRandom.uuid}"
            # Replay precedes cap checks, notices and denied-attempt telemetry.
            next if Transaction.exists?(organization: owner.organization, idempotency_key: source_key)
            next if AwardAdmission.exists?(organization: owner.organization, source_key:)

            if action == :report
              report = report_source(owner, source_key, metadata)
              report.lock!
              amount = if metadata["corroboration_id"]
                         ReportEntitlement.outcome_target(ReportEntitlement.root(report)).positive? && ReportEntitlement.available?(report, account:, source_key:, occurred_at:) ? ReportEntitlement::DUPLICATE_POINTS : 0
                       else
                         ReportEntitlement.target(report, account:, source_key:, occurred_at:)
                       end
            end
            denied = cap && period_count(account, action, start_at, end_at) >= cap
            denied ||= action == :proposal && period == "month" && !earliest_proposal?(owner, source_key, start_at, end_at, cap)
            outcome = amount.positive? ? (denied ? "capped" : "awarded") : (action == :report ? "ineligible" : "disabled")
            attrs = (metadata || {}).stringify_keys.merge("action" => action.to_s, "occurred_at" => occurred_at.iso8601,
                                                          "award_period" => period, "rule_version" => "2026-09-v1")
            if outcome == "awarded"
              result = @ledger.award(owner, amount, reason: action.to_s, idempotency_key: source_key, metadata: attrs)
            end
            AwardAdmission.create!(organization: owner.organization, account:, source_key:, action: action.to_s,
              period:, period_start: start_at.to_date, occurred_at:, outcome:, amount: result ? amount : 0,
              ledger_transaction: result, metadata: attrs)
            capped_now = outcome == "capped"
          end
          if capped_now
            ActiveRecord.after_all_transactions_commit { notify_daily_cap_reached(owner, action, period:, reset_at: end_at) }
          end
          result
        end

        # The effective season-start moment for an organization:
        # DB override (Decidim::Bih::Setting) → host config
        # (Decidim::Bih.goodwill_season_started_at). Returns a Time/Date or nil.
        # nil organization or empty store == the config value, unchanged.
        def self.season_started_at(organization = nil)
          raw = Decidim::Bih::Setting.namespace_for(organization, SEASON_NAMESPACE)[SEASON_KEY]
          return Decidim::Bih.goodwill_season_started_at if raw.blank?

          # Time.zone.parse returns nil for an unparseable string and raises on
          # bad inputs (ArgumentError, TypeError, and — for out-of-range
          # components — RangeError). A corrupt stored value must never break a
          # public wallet read, so any parse failure falls back to config.
          Time.zone.parse(raw.to_s) || Decidim::Bih.goodwill_season_started_at
        rescue StandardError
          Decidim::Bih.goodwill_season_started_at
        end

        private

        attr_reader :ledger

        # The effective [schedule, daily_caps] for an award. When this instance
        # was built with an organization they are memoized; otherwise they are
        # resolved per-award from the owner's organization (empty store ==
        # config-only, so identical to the pre-table behavior).
        def effective_rules_for(organization)
          return [@schedule, @daily_caps] if @organization

          [merged_schedule(organization), merged_daily_caps(organization)]
        end

        # DEFAULTS+config schedule with the org's DB overrides applied on top.
        def merged_schedule(organization)
          @config_schedule.merge(int_overrides(organization, SCHEDULE_NAMESPACE))
        end

        # DEFAULTS+config caps with the org's DB overrides applied on top.
        def merged_daily_caps(organization)
          @config_daily_caps.merge(int_overrides(organization, CAPS_NAMESPACE))
        end

        # Loads a namespace's overrides as { action_symbol => Integer }, dropping
        # blanks. Returns {} when no org / empty store, so the merge is a no-op
        # and behavior is identical to the config-only path.
        def int_overrides(organization, namespace)
          Decidim::Bih::Setting.namespace_for(organization, namespace).each_with_object({}) do |(key, value), acc|
            next if value.nil? || value.to_s.strip.empty?

            acc[key.to_sym] = value.to_i
          end
        end

        def lock_owner!(owner)
          AccountLocks.lock!(ledger.account_for(owner))
        end

        def report_source(owner, source_key, metadata)
          if metadata["corroboration_id"]
            record = ReportCorroboration.find_by!(organization: owner.organization, user: owner, id: metadata["corroboration_id"])
            record.report
          else
            match = source_key.match(/\Abih_report:(\d+)\z/)
            raise ArgumentError, "report source required" unless match
            Decidim::Bih::Report.find_by!(organization: owner.organization, author: owner, id: match[1])
          end
        end

        def validate_proposal_source!(owner, source_key)
          match = source_key.to_s.match(/\Aproposal:(\d+):author:(\d+)\z/)
          raise ArgumentError, "proposal source author mismatch" unless match && match[2].to_i == owner.id
          proposal = Decidim::Proposals::Proposal.find(match[1])
          raise ArgumentError, "proposal source organization mismatch" unless proposal.organization == owner.organization
          unless proposal.coauthorships.exists?(decidim_author_id: owner.id, decidim_author_type: owner.class.base_class.name)
            raise ArgumentError, "proposal source author missing"
          end
        end

        def source_time(action, source_key, metadata)
          if action == :report && source_key.to_s.match?(/\Abih_report:\d+\z/)
            return Decidim::Bih::Report.find(source_key.delete_prefix("bih_report:")).created_at
          end
          if action == :proposal && (match = source_key.to_s.match(/\Aproposal:(\d+):author:\d+\z/))
            proposal = Decidim::Proposals::Proposal.find(match[1])
            recorded = metadata["occurred_at"]
            return Time.iso8601(recorded) if recorded.present?
            raise ArgumentError, "proposal was not published" unless proposal.published_at
            return proposal.published_at
          end
          value = metadata.to_h["occurred_at"] || metadata.to_h[:occurred_at]
          value.present? ? Time.iso8601(value.to_s) : Time.current
        end

        def period_count(account, action, start_at, end_at)
          admissions = AwardAdmission.awarded.where(account:, action: action.to_s, occurred_at: start_at...end_at)
          recorded_ids = AwardAdmission.where(account:, action: action.to_s).where.not(transaction_id: nil).select(:transaction_id)
          legacy = Transaction.where(organization: account.organization, kind: "earn", reason: action.to_s, created_at: start_at...end_at)
                              .where.not(id: recorded_ids).joins(:entries)
                              .where(decidim_bih_goodwill_entries: { decidim_bih_goodwill_account_id: account.id })
                              .where("decidim_bih_goodwill_entries.amount > 0").distinct.count
          admissions.count + legacy
        end

        def earliest_proposal?(owner, source_key, start_at, end_at, cap)
          return true unless cap
          match = source_key.to_s.match(/\Aproposal:(\d+):author:(\d+)\z/)
          return false unless match && match[2].to_i == owner.id
          connection = Account.connection
          ids = connection.select_values(<<~SQL)
            SELECT DISTINCT p.id, p.published_at
            FROM decidim_proposals_proposals p
            JOIN decidim_coauthorships c ON c.coauthorable_id=p.id AND c.coauthorable_type='Decidim::Proposals::Proposal'
            JOIN decidim_components component ON component.id=p.decidim_component_id
            WHERE c.decidim_author_id=#{Integer(owner.id)} AND c.decidim_author_type=#{connection.quote(owner.class.base_class.name)}
              AND p.published_at >= #{connection.quote(start_at)} AND p.published_at < #{connection.quote(end_at)}
            ORDER BY p.published_at,p.id LIMIT #{Integer(cap)}
          SQL
          ids.map(&:to_i).include?(match[1].to_i)
        end

        def capped?(owner, action, daily_caps = @daily_caps)
          cap = daily_caps[action.to_sym]
          return false if cap.nil?

          today_count(owner, action) >= cap
        end

        # Javi građaninu jednom po radnji po danu da je dnevna granica bodova
        # dostignuta. Nikad ne diže izuzetak — dodjela je važnija od poruke.
        def notify_daily_cap_reached(owner, action, period: "day", reset_at: Time.current.end_of_day)
          return unless owner.is_a?(Decidim::User)
          return unless claim_daily_cap_notice!(owner, action, period:, at: reset_at - 1.second)

          # Isti obrazac koji engine vec koristi (KomsilukPostNotificationJob,
          # OperatorRoleExpiryNotifier). force_send preskace `notifiable?`, koji
          # bi inace progutao obavijest jer vlasnik ne "prati" sam sebe.
          Decidim::EventsManager.publish(
            event: "decidim.events.bih.goodwill.daily_cap_reached",
            event_class: Decidim::Bih::Goodwill::DailyCapReachedEvent,
            resource: owner,
            affected_users: [owner],
            force_send: true,
            extra: { "reason" => action.to_s, "period" => period, "reset_at" => reset_at.iso8601 }
          )
        rescue StandardError => e
          Rails.logger.error("[goodwill] daily cap notice failed: #{e.class}: #{e.message}")
          nil
        end

        # Atomski pokušaj zauzimanja "poslato" slota za owner+radnju+dan.
        # `unless_exist: true` čini provjeru-pa-upis jednim atomskim upisom, pa
        # dvije konkurentne dodjele (goodwill red radi na concurrency 5, vidi
        # config/sidekiq.yml) ne mogu obje pomisliti da su prve — vraća true
        # SAMO onome ko stvarno zauzme ključ. Ako upis u cache ne uspije (npr.
        # Redis nedostupan), biramo da NE pošaljemo obavijest nego da je
        # eventualno ponovimo, umjesto da je šaljemo na svaku zaustavljenu
        # radnju dok je cache nedostupan.
        def claim_daily_cap_notice!(owner, action, period: "day", at: Time.current)
          Rails.cache.write(daily_cap_notice_key(owner, action, period:, at:), true, expires_in: period == "month" ? 32.days : 24.hours, unless_exist: true)
        end

        # Ključ je vezan za kalendarski dan u zoni aplikacije (Europe/Sarajevo),
        # istu granicu koju koristi today_count.
        def daily_cap_notice_key(owner, action, period: "day", at: Time.current)
          day = period == "month" ? at.in_time_zone("Europe/Sarajevo").beginning_of_month.to_date : at.in_time_zone("Europe/Sarajevo").to_date
          "goodwill:cap-notice:#{owner.organization.id}:#{owner.id}:#{action}:#{period}:#{day}"
        end

        # Count today's "earn" awards of this action credited to this owner's
        # account (the ledger is the source of truth — no Redis needed).
        def today_count(owner, action)
          account = ledger.account_for(owner)
          Transaction
            .where(organization: owner.organization, kind: "earn", reason: action.to_s)
            .where(decidim_bih_goodwill_transactions: { created_at: Time.zone.now.beginning_of_day.. })
            .joins(:entries)
            .where(decidim_bih_goodwill_entries: { decidim_bih_goodwill_account_id: account.id })
            .where("decidim_bih_goodwill_entries.amount > 0")
            .distinct
            .count
        end

        def symbolize(hash)
          (hash || {}).to_h.symbolize_keys
        end
      end
    end
  end
end
