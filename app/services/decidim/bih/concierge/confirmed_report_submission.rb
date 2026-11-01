# frozen_string_literal: true

require "digest"
require "json"
require_relative "dialogue/contracts"
require_relative "../report_intake"
require_relative "../goodwill/idempotency_key"

module Decidim
  module Bih
    module Concierge
      # Called only by the server's exact, raw confirmation-command boundary.
      # Provider output cannot grant write_report or construct a trusted draft.
      # A receipt commits with the report; retries replay pending jobs, not intake.
      class ConfirmedReportSubmission
        Receipt = Data.define(:reference, :replayed)
        InvalidDraft = Class.new(ArgumentError)
        Unavailable = Class.new(StandardError)
        CONFIRMED_EVENT = "report_chat_confirmed"
        DISPATCHED_EVENT = "report_chat_effects_dispatched"
        MAX_DRAFT_AGE = 15 * 60
        DISCLOSURE_VERSION = "exact_public_location_v1"
        DRAFT_KEYS = %w(id code organization_id actor_id conversation_key description address latitude longitude possible_duplicates locale expires_at).freeze
        JOBS = %w(Decidim::Bih::ReportProcessingJob Decidim::Bih::ReportStaffAlertJob Decidim::Bih::Goodwill::GoodwillAwardJob).freeze

        # Only this caller owns an outer receipt transaction. Savepoints keep a
        # reference collision from poisoning it; other intake callers are intact.
        class Intake < Decidim::Bih::ReportIntake
          private

          def save_with_reference_retry(report, attempts: 3)
            report.class.transaction(requires_new: true) { report.save! }
          rescue ActiveRecord::RecordNotUnique
            attempts -= 1
            raise if attempts <= 0

            report.reference = nil
            retry
          end

          def award_contribution(report, author)
            return unless author

            Decidim::Bih::DurableEffects.enqueue(
              Decidim::Bih::Goodwill::GoodwillAwardJob,
              owner: author, action: "report",
              idempotency_key: Decidim::Bih::Goodwill::IdempotencyKey.report(report.id)
            )
            nil
          end

          # Unlike best-effort form intake, a receipt must retain this effect or
          # roll back. It must never acknowledge a silently dropped enqueue.
          def enqueue_processing(report, locale)
            Decidim::Bih::DurableEffects.enqueue(processing_job, report.id, locale:)
            report.record_event!("processing_enqueued", source: "background", actor_role: "system", metadata: { locale: })
          end
        end

        def call(context:, draft:, author: nil)
          submit(context:, draft:, author:, replay_only: false)
        end

        # Old previews can recover an already committed receipt, but can never
        # create a report without the current public-location disclosure.
        def replay(context:, draft:, author: nil)
          submit(context:, draft:, author:, replay_only: true)
        end

        private

        # Keep validation, the receipt transaction and post-commit replay in one
        # ordered boundary; none of these guards may retry the business effect.
        def submit(context:, draft:, author:, replay_only:) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
          disclosure = draft["disclosure_version"] || draft[:disclosure_version] if draft.is_a?(Hash)
          draft = validated_draft(context, draft, author)
          raise InvalidDraft, "Current public-location disclosure required" unless replay_only || disclosure == DISCLOSURE_VERSION

          digest = Digest::SHA256.hexdigest(JSON.generate(draft.values_at("organization_id", "actor_id", "conversation_key", "id")))
          fingerprint = Digest::SHA256.hexdigest(JSON.generate(draft))

          Decidim::Bih::Report.connection_pool.with_connection do |connection|
            raise Unavailable, "Submission must own its transaction and effects" if connection.transaction_open? || Decidim::Bih::DurableEffects.active?

            with_receipt_lock(connection, digest) do
              replayed = false
              event = Decidim::Bih::Report.transaction do
                existing = find_receipt(context.organization_id, digest)
                replayed = !existing.nil?
                existing || (create_receipt(context, draft, author, digest, fingerprint) unless replay_only)
              end
              next unless event

              raise InvalidDraft, "Confirmation draft changed" unless event.metadata.fetch("draft_digest") == fingerprint

              dispatch_pending(event, digest)
              Receipt.new(reference: event.report.reference, replayed:)
            end
          end
        end

        def validated_draft(context, draft, author)
          validate_context!(context)
          normalized = Dialogue::Contracts.object!(draft, DRAFT_KEYS + %w(state_version disclosure_version))
          # These server-owned preview fields do not change the original draft
          # digest, so a legacy receipt remains recoverable before any rotation.
          normalized.delete("disclosure_version")
          version = normalized.delete("state_version")
          raise InvalidDraft, "Invalid state version" unless version.nil? || (version.is_a?(Integer) && version >= 0)
          raise InvalidDraft, "Incomplete confirmation draft" unless normalized.keys.sort == DRAFT_KEYS.sort
          raise InvalidDraft, "Confirmation scope mismatch" unless normalized.values_at("organization_id", "actor_id", "conversation_key") ==
                                                                   [context.organization_id, context.actor_id, context.conversation_key]
          raise InvalidDraft, "Invalid confirmation identity" unless hex?(normalized["id"], 48) && hex?(normalized["code"], 12)

          validate_expiry!(normalized["expires_at"], context)
          validate_author!(author, context)
          validate_fields!(normalized)
          # Stable ordering also makes equivalent symbol/string-key retries safe.
          DRAFT_KEYS.to_h { |key| [key, normalized.fetch(key)] }
        end

        def validate_context!(context)
          raise InvalidDraft, "Confirmed report capability required" unless
            context.is_a?(Dialogue::Contracts::TrustedContext) && context.allows?("write_report")
        end

        def validate_expiry!(expires_at, context)
          unless expires_at.is_a?(Numeric) && expires_at.finite? &&
                 expires_at > [Time.now.to_f, context.now.to_f].max && expires_at <= context.now.to_f + MAX_DRAFT_AGE
            raise InvalidDraft, "Confirmation expired or invalid"
          end
        end

        def validate_author!(author, context)
          return if author.nil? && context.actor_id.nil?
          return if author.is_a?(Decidim::User) && author.persisted? &&
                    author.id == context.actor_id && author.decidim_organization_id == context.organization_id

          raise InvalidDraft, "Report author scope mismatch"
        end

        def validate_fields!(draft)
          raise InvalidDraft, "Invalid report description" unless bounded_text?(draft["description"], 1000)
          raise InvalidDraft, "Invalid report address" unless draft["address"].nil? || bounded_text?(draft["address"], 300)
          raise InvalidDraft, "Invalid report locale" unless Dialogue::Contracts::LOCALES.include?(draft["locale"])
          raise InvalidDraft, "Invalid duplicate warning" unless [true, false].include?(draft["possible_duplicates"])

          validate_location!(draft)
        end

        def validate_location!(draft)
          latitude, longitude = draft.values_at("latitude", "longitude")
          coordinates = coordinate?(latitude, -90, 90) && coordinate?(longitude, -180, 180)
          raise InvalidDraft, "Invalid report coordinates" unless coordinates || (latitude.nil? && longitude.nil?)
          raise InvalidDraft, "Report location required" unless coordinates || draft["address"]
        end

        def bounded_text?(value, maximum)
          value.is_a?(String) && value.valid_encoding? && value == value.strip &&
            !value.empty? && value.length <= maximum && !value.match?(/[\x00-\x1f\x7f]/)
        end

        def coordinate?(value, minimum, maximum)
          value.is_a?(Numeric) && value.finite? && value.between?(minimum, maximum)
        end

        def hex?(value, length)
          value.is_a?(String) && value.match?(/\A[a-f0-9]{#{length}}\z/)
        end

        def with_receipt_lock(connection, digest)
          # Session scope also serializes the post-commit enqueue/marker gap.
          # A crash can replay an enqueue, but can never create a second report.
          lock_id = [digest[0, 16]].pack("H*").unpack1("q>")
          previous_timeout = connection.select_value("SHOW statement_timeout")
          previous_lock_timeout = connection.select_value("SHOW lock_timeout")
          connection.execute("SET statement_timeout = '5s'")
          connection.execute("SET lock_timeout = '1s'")
          acquired = connection.select_value("SELECT pg_try_advisory_lock(#{lock_id})") == true
          raise Unavailable, "Report confirmation busy" unless acquired

          yield
        ensure
          connection.select_value("SELECT pg_advisory_unlock(#{lock_id})") if acquired
          connection.execute("SET statement_timeout = #{connection.quote(previous_timeout)}") if previous_timeout
          connection.execute("SET lock_timeout = #{connection.quote(previous_lock_timeout)}") if previous_lock_timeout
        end

        def find_receipt(organization_id, digest)
          events = Decidim::Bih::ReportEvent.where(decidim_organization_id: organization_id, event_type: CONFIRMED_EVENT)
          events.where("metadata->>'confirmation_digest' = ?", digest).first
        end

        def create_receipt(context, draft, author, digest, fingerprint)
          organization = Decidim::Organization.find(context.organization_id)
          captured = Decidim::Bih::DurableEffects.capture do
            Intake.new.call(
              organization:, author:, description: draft.fetch("description"), address: draft["address"],
              latitude: draft["latitude"], longitude: draft["longitude"], locale: draft.fetch("locale"),
              # Legacy column only: Report#public_location always follows the
              # exact-public policy acknowledged by DISCLOSURE_VERSION above.
              anonymous: true, public_location_exact: false, reporter_email: nil, reporter_phone: nil, photo: nil
            )
          end
          validate_effects!(captured.effects)
          # Do not use Report#record_event!: it can silently skip a missing table.
          Decidim::Bih::ReportEvent.create!(
            report: captured.result, organization:, actor: author, event_type: CONFIRMED_EVENT,
            source: "public", actor_role: author ? "citizen" : "public",
            metadata: { "confirmation_digest" => digest, "draft_digest" => fingerprint, "disclosure_version" => DISCLOSURE_VERSION,
                        "effects_json" => JSON.generate(captured.effects) }
          )
        end

        def validate_effects!(effects)
          Decidim::Bih::DurableEffects.validate_effects!(effects)
          unless effects.any? { |effect| effect["job_class"] == "Decidim::Bih::ReportProcessingJob" } &&
                 effects.all? { |effect| effect["type"] == "active_job" && JOBS.include?(effect["job_class"]) }
            raise Unavailable, "Unexpected report effects"
          end
        end

        def dispatch_pending(event, digest)
          return if event.report.events.where(event_type: DISPATCHED_EVENT).exists?(["metadata->>'confirmation_digest' = ?", digest])

          effects = JSON.parse(event.metadata.fetch("effects_json"))
          validate_effects!(effects)
          effects.each { |effect| Decidim::Bih::DurableEffects.dispatch!(effect) }
          Decidim::Bih::ReportEvent.create!(
            report: event.report, organization: event.organization, event_type: DISPATCHED_EVENT,
            source: "system", actor_role: "system", metadata: { "confirmation_digest" => digest }
          )
        end
      end
    end
  end
end
