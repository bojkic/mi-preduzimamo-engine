# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      class Review
        class Invalid < StandardError; end
        SETTINGS = %w(review_closes_at vote_starts_at vote_ends_at tie_procedure zero_entry_procedure project_owner winners).freeze
        def self.authorize!(organization, actor)
          raise Decidim::ActionForbidden unless actor&.admin? && actor.decidim_organization_id == organization.id && !actor.blocked? && !actor.deleted?
        end

        def initialize(organization)
          @organization = organization
          @config = Config.new(organization:)
        end

        def edition = Edition.ensure_for!(@organization)

        def baseline!(actor:, reason:)
          authorize_reason!(actor, reason)
          ed = edition
          ed.with_lock do
            return { replay: true, at: ed.baseline_at } if ed.baseline_at
            raise Invalid, "race already closed" if @config.finished?
            before = Scorer.new(organization: @organization).rows
            Decidim::Bih::CitizenProfile.where(organization: @organization).order(:id).lock.each do |profile|
              Membership.capture!(ed, profile, provenance: "cutover_baseline")
            end
            ed.update!(baseline_at: Time.current)
            after = Scorer.new(organization: @organization).rows
            raise Invalid, "baseline changed standings" unless before == after
            ed.record!("baseline", actor:, reason:, rows: after, memberships: ed.memberships.count)
            { at: ed.baseline_at, rows: after }
          end
        end

        # Called by the scheduled task; this captures evidence, never winners.
        def capture!(actor: nil)
          self.class.authorize!(@organization, actor) if actor
          raise Invalid, "cutoff has not passed" unless @config.finished?
          ed = edition
          ed.with_lock do
            return ed if ed.captured_at
            raise Invalid, "membership baseline missing" unless ed.baseline_at
            snapshot = SnapshotBuilder.new(organization: @organization, config: @config, at: @config.window_to).call
            now = Time.current
            snapshot["captured_at"] = now.iso8601(6)
            snapshot["delay_seconds"] = [now - @config.window_to, 0].max.round(3)
            calculator = Calculator.new(snapshot)
            snapshot["initial_rows"] = calculator.rows
            snapshot["initial_evidence"] = calculator.evidence
            ed.update!(snapshot:, snapshot_digest: Edition.digest(snapshot), captured_at: now)
            ed.record!("capture", actor:, digest: ed.snapshot_digest, cutoff: @config.window_to.iso8601,
                       actual_at: now.iso8601, delay_seconds: snapshot["delay_seconds"])
          end
          ed
        end

        def decide!(actor:, reason:, item_key:, include_item:, area: nil, expected_digest:)
          authorize_reason!(actor, reason)
          ed = edition
          ed.with_lock do
            mutable_review!(ed, expected_digest)
            item = ed.snapshot.fetch("items").find { |candidate| candidate["key"] == item_key }
            raise Invalid, "unknown captured item" unless item
            if include_item && (!item["user_id"] || !item["at"])
              raise Invalid, "missing source identity/time"
            end
            area = Integer(area) if area.present?
            raise Invalid, "area outside captured roster" if area && ed.snapshot.fetch("areas").none? { |a| a["id"] == area }
            data = { "include" => include_item, "reason" => reason }
            data["area"] = area if area
            return if decisions(ed)[item_key] == data
            ed.record!("adjudication", actor:, item_key:, **data.symbolize_keys)
          end
        end

        def decisions(ed = edition)
          ed.events.where(kind: "adjudication").order(:id).each_with_object({}) { |event, h| h[event.item_key] = event.data }
        end

        def preview
          ed = edition
          return Scorer.new(organization: @organization).rows unless ed.captured_at
          verify_digest!(ed)
          Calculator.new(ed.snapshot, decisions: decisions(ed)).rows
        end

        def electorate
          ed = edition
          rows = (ed.snapshot["electorate"] || []).index_by { |row| row["user_id"].to_s }
          ed.events.where(kind: "electorate").order(:id).each do |event|
            rows[event.item_key] = event.data["member"]
          end
          rows.values.compact
        end

        def correct_elector!(actor:, reason:, user_id:, area:, expected_digest:, evidence: nil)
          authorize_reason!(actor, reason)
          ed = edition
          ed.with_lock do
            mutable_review!(ed, expected_digest)
            user_id = Integer(user_id)
            original = ed.snapshot.fetch("electorate").find { |row| row["user_id"] == user_id }
            unless original
              captured_identity = ed.snapshot.fetch("items").any? { |row| row["user_id"] == user_id }
              raise Invalid, "uncaptured identity; evidence review required" unless captured_identity
              raise Invalid, "cutoff qualification evidence required" if evidence.to_s.strip.empty?
              original = { "user_id" => user_id, "provenance" => "adjudicated_cutoff_evidence", "evidence" => evidence.to_s }
            end
            area = Integer(area) if area.present?
            raise Invalid, "area outside captured roster" if area && ed.snapshot.fetch("areas").none? { |a| a["id"] == area }
            member = area ? original.merge("area" => area) : nil
            ed.record!("electorate", actor:, item_key: user_id.to_s, reason:, member:)
          end
        end

        def correct_membership!(actor:, reason:, user_id:, area:, expected_area:, preview_only: false, expected_preview: nil)
          authorize_reason!(actor, reason)
          ed = edition
          result = nil
          ed.with_lock(requires_new: true) do
            raise Invalid, "use captured-item adjudication after cutoff" if @config.finished? || ed.captured_at
            member = ed.memberships.find_by!(decidim_user_id: user_id)
            raise Invalid, "membership changed; refresh preview" unless member.komsiluk_id == Integer(expected_area)
            target = Decidim::Bih::LocalArea.find_by!(id: area, organization: @organization, kind: "komsiluk")
            before = Scorer.new(organization: @organization).rows
            old = member.komsiluk_id
            member.update!(komsiluk: target)
            after = Scorer.new(organization: @organization).rows
            result = { before:, after:, digest: Edition.digest(user_id: member.decidim_user_id, old:, target: target.id, before:, after:) }
            raise ActiveRecord::Rollback if preview_only
            raise Invalid, "membership impact changed; preview again" unless expected_preview == result[:digest]
            ed.record!("membership_correction", actor:, reason:, user_id: member.decidim_user_id,
                       before_area: old, after_area: target.id, before:, after:)
          end
          result
        end

        def settings!(actor:, values:, reason:)
          authorize_reason!(actor, reason)
          incoming = values.stringify_keys.slice(*SETTINGS)
          %w(review_closes_at vote_starts_at vote_ends_at).each do |key|
            next if incoming[key].blank?
            incoming[key] = @config.zone.parse(incoming[key].to_s).iso8601
          end
          ed = edition
          ed.with_lock do
            raise Invalid, "already final" if ed.finalized_at
            merged = ed.settings.merge(incoming)
            if merged["vote_starts_at"].present? && merged["vote_ends_at"].present? && Time.iso8601(merged["vote_starts_at"]) >= Time.iso8601(merged["vote_ends_at"])
              raise Invalid, "vote dates are not ordered"
            end
            ed.update!(settings: merged)
            ed.record!("settings", actor:, reason:, values: incoming)
          end
        rescue ArgumentError, TypeError
          raise Invalid, "invalid review settings"
        end

        def finalize!(actor:, reason:, expected_digest:, expected_revision:)
          authorize_reason!(actor, reason)
          raise Invalid, "cutoff has not passed" unless @config.finished?
          ed = edition
          ed.with_lock do
            return 0 if ed.finalized_at
            mutable_review!(ed, expected_digest)
            raise Invalid, "review changed; refresh preview" unless ed.events.maximum(:id).to_i == Integer(expected_revision)
            %w(review_closes_at project_owner tie_procedure zero_entry_procedure).each do |key|
              raise Invalid, "missing #{key}" if ed.settings[key].blank?
            end
            raise Invalid, "review period is open" if Time.current < Time.iso8601(ed.settings.fetch("review_closes_at"))
            rows = preview
            unresolved = ed.snapshot.fetch("items").select { |item| item.dig("facts", "review_state").in?(%w(pending needs_information)) }
            raise Invalid, "pending report decisions" if unresolved.any? { |item| !decisions(ed).key?(item["key"]) }
            rows.group_by { |row| row[:zona] }.each do |zone, league|
              top = league.first
              tied = league.select { |r| r[:score] == top[:score] && r[:reached_at] == top[:reached_at] }
              chosen = ed.settings.fetch("winners", {})[zone]
              if top[:score].positive? && tied.length == 1 && chosen.present? && chosen.to_s != top[:komsiluk_id].to_s
                raise Invalid, "winner must follow the scored result"
              end
              if top[:score].zero? || tied.length > 1
                raise Invalid, "explicit #{zone} winner/no-award disposition required" unless chosen.to_s == "none" || tied.any? { |r| r[:komsiluk_id].to_s == chosen.to_s }
              end
            end
            count = Standings.new(@organization).write_snapshot!(rows, final: true)
            digest = Edition.digest(snapshot: ed.snapshot_digest, decisions: decisions(ed), electorate: electorate, rows:)
            ed.update!(finalized_at: Time.current, finalized_by_id: actor.id, final_digest: digest)
            ed.record!("finalized", actor:, reason:, digest:, rows:, electorate: electorate)
            count
          end
        end

        private

        def authorize_reason!(actor, reason)
          self.class.authorize!(@organization, actor)
          raise Invalid, "reason required" if reason.to_s.strip.empty?
        end

        def verify_digest!(ed)
          raise Invalid, "capture integrity mismatch" unless ed.snapshot_digest == Edition.digest(ed.snapshot)
        end

        def mutable_review!(ed, digest)
          raise Invalid, "already final" if ed.finalized_at
          raise Invalid, "capture missing" unless ed.captured_at
          verify_digest!(ed)
          raise Invalid, "stale evidence" unless digest.to_s == ed.snapshot_digest
        end
      end
    end
  end
end
