# frozen_string_literal: true

# rubocop:disable Layout/LineLength -- explicit schema and correlated SQL guards kept together

module Decidim
  module Bih
    module ReportObligations
      DEADLINES = { review: 2, dispatch_approval: 2, closure_approval: 2, info_request: 7,
                    evidence_collection: 7, evidence_handoff: 2, city_response: 21, city_commitment: nil,
                    mail_review: 2, dispute_review: 2, delivery_exception: 1 }.freeze
      ACTOR_FOR = { review: "staff", dispatch_approval: "staff", closure_approval: "staff", info_request: "citizen",
                    evidence_collection: "citizen", evidence_handoff: "system", city_response: "city", city_commitment: "city",
                    mail_review: "staff", dispute_review: "staff", delivery_exception: "staff" }.freeze

      module_function

      # rubocop:disable Metrics/ParameterLists -- typed obligation provenance and idempotency
      def open!(report, kind:, actor: nil, source: nil, due_at: nil, metadata: {}, effect_key: nil, policy_key: nil)
        key = kind.to_sym
        attributes = { kind: key.to_s, actor: actor || ACTOR_FOR.fetch(key), source:, due_at: due_at || deadline(key), metadata:, effect_key:, policy_key: }
        report.with_lock do
          existing = effect_key && report.obligations.find_by(effect_key:)
          existing || report.obligations.create!(attributes)
        end
      end

      # rubocop:enable Metrics/ParameterLists
      def deadline(kind, at: Time.current)
        days = DEADLINES.fetch(kind.to_sym)
        days && (at + days.days.to_i)
      end

      def fulfil!(obligation, by:)
        obligation.report.with_lock do
          obligation.reload
          if obligation.open?
            obligation.update!(state: "fulfilled", fulfilled_by: by)
            settle_inbound_email!(obligation)
          end
        end
        obligation
      end

      def supersede!(obligation, by:, replacements: [])
        obligation.report.with_lock do
          obligation.reload
          return obligation unless obligation.open?

          obligation.update!(state: "superseded", fulfilled_by: by)
          settle_inbound_email!(obligation)
          replacements.each { |attributes| open!(obligation.report, **attributes.symbolize_keys) }
        end
        obligation
      end

      # An open mail-review task is what keeps a linked e-mail in the mailbox
      # review list. Once no case still has one, the e-mail is handled; before
      # this, seven e-mails of 06.10 stayed listed after their cases were done.
      def settle_inbound_email!(obligation)
        email = obligation.source
        return unless obligation.kind == "mail_review" && email.is_a?(InboundEmail) && email.state == "review"
        return if ReportObligation.open.exists?(kind: "mail_review", source: email)

        email.update!(state: "processed")
      end

      # A closed case waits on nobody: its citizen and City clocks end with it.
      # Staff approvals and exceptions stay explicit (owner decision 2026-10-06).
      # The caller is the report's own update, already inside its transaction.
      WAITING_ACTORS = %w(citizen city).freeze

      def close_waiting!(report)
        return unless ReportObligation.available?

        report.obligations.open.where(actor: WAITING_ACTORS).find_each do |task|
          task.update!(state: "superseded", fulfilled_by: report, metadata: task.metadata.merge("closed_reason" => "case_closed"))
        end
      end

      # A staff-approved dispatch starts a fresh clock for its service thread.
      # Keep commitments and other service conversations independent, except
      # that a follow-up chases every unanswered City wait of the case: an
      # older wait on another thread otherwise stayed overdue (BR-2026-0072).
      def after_dispatch!(dispatch)
        report = dispatch.report
        recipients = Array(dispatch.snapshot["to"]).sort
        report.obligations.open.where(kind: "city_response").find_each do |task|
          source = task.source
          same_thread = source.is_a?(ReportDispatch) && Array(source.snapshot["to"]).sort == recipients
          supersede!(task, by: dispatch) if source.nil? || same_thread || dispatch.kind == "followup"
        end
        open!(report, kind: "city_response", source: dispatch,
                      due_at: deadline(:city_response, at: dispatch.accepted_at),
                      effect_key: "accepted-dispatch:#{dispatch.id}:city_response",
                      metadata: { origin: "accepted_dispatch" })
      end

      def for_report(report)
        return derive(report) unless ReportObligation.available?
        return [] if ReportWorkQueue.closed?(report)

        stored = report.obligations.to_a
        identities = stored.map { |task| obligation_identity(task) }
        stored.select(&:open?) + derive(report).reject do |task|
          identities.include?(obligation_identity(task)) || (task.kind == "city_response" && stored.any? { |item| %w(city_response city_commitment).include?(item.kind) })
        end
      end

      def obligation_identity(task)
        [task.kind, task.actor, task.source_type, task.source_id]
      end

      def next_action(report)
        for_report(report).min_by { |o| [o.due_at || Time.utc(9999), o.id || 0] }
      end

      def answered_by(report, citizen_message)
        requests = report.obligations.open.where(kind: "info_request").to_a
        answer_id = citizen_message.respond_to?(:answers_message_id) && citizen_message.answers_message_id
        if answer_id
          matches = requests.select { |o| o.source_type == "Decidim::Bih::ReportMessage" && o.source_id == answer_id }
          return matches.first if matches.one?
          return if matches.empty?

          return :ambiguous
        end
        return :ambiguous if requests.size > 1

        requests.first
      end

      # Before cutover these are unsaved display objects. No state or race writes.
      # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity -- exhaustive legacy stage projection
      def derive(report)
        return [] if %w(rijeseno odbijeno zatvoreno).include?(report.status) || report.duplicate?

        result = []
        legacy = ->(key) { report.has_attribute?(key) ? report[key] : nil }
        review = legacy.call(:review_state)
        if review == "pending"
          anchor = legacy.call(:review_pending_since) || report.last_citizen_reply_at || report.created_at || Time.current
          result << build(report, "review", applicable_due(report, "review") || deadline(:review, at: anchor))
        elsif review == "needs_information"
          question = report.case_messages.where(actor_role: "staff", kind: "question").order(created_at: :desc, id: :desc).first
          result << build(report, "info_request", applicable_due(report, "citizen") || (question && deadline(:info_request, at: question.created_at)), source: question)
        elsif report.status == "primljeno" && [nil, "", "validated"].include?(review)
          result << build(report, "review", applicable_due(report, "review") || deadline(:review, at: report.reviewed_at || report.created_at || Time.current))
        end
        if report.forwarded_at
          # Citizen questions never extinguish the service's independent obligation.
          city_due = review == "validated" ? applicable_due(report, "city") : nil
          result << build(report, "city_response", city_due || deadline(:city_response, at: report.forwarded_at))
        end
        result << build(report, "review", applicable_due(report, "planning") || report.report_collection&.review_due_at) if report.planned? && review != "pending"
        result
      end

      # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Keep operator dates, but never reuse a citizen-question date as a City date.
      def applicable_due(report, kind)
        deadline_kind = report.has_attribute?(:deadline_kind) && report.deadline_kind
        report.response_due_at if deadline_kind.blank? || deadline_kind == kind || (kind == "city" && deadline_kind == "review")
      end

      # Materialise legacy tasks without changing lifecycle or race inputs. A
      # completed/superseded identity suppresses re-derivation on later reads.
      def materialize!(report, actor:)
        report.with_lock do
          stored = report.obligations.to_a.map { |task| obligation_identity(task) }
          derive(report).each do |task|
            next if stored.include?(obligation_identity(task))

            task.effect_key = "legacy-task:#{report.id}:#{task.kind}:#{task.source_id || 0}"
            task.metadata = { origin: "legacy_reconciliation", actor_id: actor.id }
            task.save!
          end
          report.obligations.reset
        end
        for_report(report)
      end

      # SQL selection uses precisely the same derived identities and deadline
      # precedence as the task presenter. Stored terminal tasks suppress their
      # legacy projection without suppressing unrelated questions/conversations.
      def deadline_sql(table: Report.table_name)
        tasks = ReportObligation.table_name
        question = "(SELECT m.id FROM decidim_bih_report_messages m WHERE m.report_id = #{table}.id AND m.actor_role = 'staff' AND m.kind = 'question' ORDER BY m.created_at DESC, m.id DESC LIMIT 1)"
        question_at = "(SELECT m.created_at FROM decidim_bih_report_messages m WHERE m.id = #{question})"
        explicit = lambda { |kind|
          "CASE WHEN #{table}.deadline_kind IS NULL OR #{table}.deadline_kind = '' OR #{table}.deadline_kind = '#{kind}' #{kind == "city" ? "OR #{table}.deadline_kind = 'review'" : ""} THEN #{table}.response_due_at END"
        }
        suppress = lambda do |kind, actor, source_id = "NULL", source_type = "NULL"|
          "NOT EXISTS (SELECT 1 FROM #{tasks} o WHERE o.report_id = #{table}.id AND o.kind = '#{kind}' AND o.actor = '#{actor}' AND o.source_id IS NOT DISTINCT FROM #{source_id} AND o.source_type IS NOT DISTINCT FROM #{source_type})"
        end
        review = "CASE WHEN #{table}.review_state = 'pending' THEN COALESCE(#{explicit.call("review")}, COALESCE(#{table}.review_pending_since, #{table}.last_citizen_reply_at, #{table}.created_at) + INTERVAL '#{DEADLINES[:review]} days') WHEN #{table}.review_state = 'validated' AND #{table}.status = 'primljeno' THEN COALESCE(#{explicit.call("review")}, COALESCE(#{table}.reviewed_at, #{table}.created_at) + INTERVAL '#{DEADLINES[:review]} days') WHEN #{table}.status = 'planirano' AND #{table}.review_state <> 'pending' THEN COALESCE(#{explicit.call("planning")}, (SELECT c.review_due_at FROM decidim_bih_report_collections c WHERE c.id = #{table}.report_collection_id)) END"
        citizen = "CASE WHEN #{table}.review_state = 'needs_information' THEN COALESCE(#{explicit.call("citizen")}, #{question_at} + INTERVAL '#{DEADLINES[:info_request]} days') END"
        city = "CASE WHEN #{table}.forwarded_at IS NOT NULL THEN COALESCE(CASE WHEN #{table}.review_state = 'validated' THEN #{explicit.call("city")} END, #{table}.forwarded_at + INTERVAL '#{DEADLINES[:city_response]} days') END"
        <<~SQL.squish
          (SELECT MIN(effective.due_at) FROM (
            SELECT o.due_at FROM #{tasks} o WHERE o.report_id = #{table}.id AND o.state = 'open'
            UNION ALL SELECT #{review} WHERE #{suppress.call("review", "staff")}
            UNION ALL SELECT #{citizen} WHERE #{suppress.call("info_request", "citizen", question, "CASE WHEN #{question} IS NOT NULL THEN 'Decidim::Bih::ReportMessage' END")}
            UNION ALL SELECT #{city} WHERE NOT EXISTS (SELECT 1 FROM #{tasks} o WHERE o.report_id = #{table}.id AND o.kind IN ('city_response','city_commitment'))
          ) effective)
        SQL
      end

      def build(report, kind, due_at, source: nil)
        ReportObligation.new(report:, kind:, actor: ACTOR_FOR.fetch(kind.to_sym), due_at:, source:, state: "open")
      end

      def label(obligation, locale: I18n.locale)
        I18n.t("decidim.bih.report_obligations.#{obligation.kind}", locale:)
      end
    end
  end
end

# rubocop:enable Layout/LineLength
