# frozen_string_literal: true

module Decidim
  module Bih
    module Messaging
      # One delivery leg of an intent.
      #
      # The statuses keep apart things that are routinely conflated: a provider
      # ACCEPTING a request is not handset delivery, an unknown outcome is not a
      # failure, and an expired payload was never sent. There is no `read`
      # status: reading has channel-specific meaning and belongs to the channel's
      # own record, not to a general ledger.
      #
      # A row is an OBSERVATION of work, never a claim about a person reading
      # anything. Bell creation is not handset delivery; SMTP acceptance is not
      # inbox placement; a push service's 201 is not a displayed notification.
      class Attempt < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_messaging_attempts"

        STATUSES = %w(queued claimed accepted delivered uncertain skipped failed expired).freeze
        # An outcome that cannot be retried automatically: we do not know whether
        # the provider already did the work.
        UNCERTAIN_STATUSES = %w(uncertain).freeze

        # What kind of thing this leg addressed. `account` covers the legs that
        # have no transport destination of their own — a bell is addressed to
        # the account, not to an address — and `redacted` is what a destination
        # becomes when its account is deleted: the operational event survives,
        # the pointer to the person does not.
        DESTINATION_KINDS = (SuppressionKey::KINDS + %w(redacted)).freeze
        REDACTED_KIND = "redacted"

        # Outcomes that prove the provider or SMTP took the request. A
        # definitive rejection is NOT here: the provider answered, but it
        # answered "never", and calling that an acceptance would read as
        # progress in every operator surface.
        ACCEPTANCE_PROVING = [Outcome::ACCEPTED, Outcome::DELIVERED].freeze

        # Outcomes that say nothing yet. Stamping `settled_at` for one of these
        # would make a leg that is still waiting look like a leg that finished.
        UNSETTLED_OUTCOMES = [Outcome::QUEUED, Outcome::CLAIMED].freeze

        belongs_to :intent, class_name: "Decidim::Bih::Messaging::Intent",
                            inverse_of: :attempts

        validates :channel_group, presence: true
        validates :channel, inclusion: { in: RecipientContext::CHANNELS }
        validates :status, inclusion: { in: STATUSES }
        validates :destination_kind, inclusion: { in: DESTINATION_KINDS }, allow_nil: true
        validates :destination_digest, length: { is: 64 }, allow_nil: true

        scope :uncertain, -> { where(status: UNCERTAIN_STATUSES) }
        scope :for_provider_message, lambda { |message_id|
          where("provider_message_id = :id OR :id = ANY(provider_message_ids)", id: message_id.to_s)
        }

        def uncertain?
          UNCERTAIN_STATUSES.include?(status)
        end

        def provider_ids
          ids = Array(provider_message_ids).map(&:to_s)
          ids.any? ? ids : Array(provider_message_id).compact.map(&:to_s)
        end

        # Record one more OBSERVATION about this leg.
        #
        # The single rule: an observation may only strengthen the claim. A later
        # PENDING_ENROUTE report cannot downgrade a delivered leg, a rollback
        # cannot reset a terminal row, and nothing resets an uncertain attempt
        # to pending to make a dashboard look tidy. {Outcome.merge} is where the
        # ordering lives; this method only applies it and stamps the two
        # timestamps that a single `settled_at` cannot keep apart.
        def observe!(outcome:, reason: nil, provider_message_ids: nil, at: Time.current)
          merged = Outcome.merge(status&.to_sym, outcome.to_sym)
          updates = { status: Outcome.attempt_status(merged) }
          updates[:settled_at] = at unless UNSETTLED_OUTCOMES.include?(merged)
          updates[:reason] = reason.to_s if reason.present? && self.reason.blank?
          updates.merge!(provider_id_updates(provider_message_ids))
          updates[:accepted_at] = at if accepted_at.nil? && ACCEPTANCE_PROVING.include?(merged)
          updates[:resolved_at] = at if resolved_at.nil? && Outcome::TERMINAL.include?(merged)
          update!(updates)
          self
        end

        # An account deletion must not leave a digest that still points at the
        # person, and must not delete the operational event either. The row
        # keeps its channel, status, reason and timestamps; only the pointer to
        # a destination goes.
        def redact_destination!
          update_columns(destination_kind: REDACTED_KIND, destination_digest: nil, # rubocop:disable Rails/SkipsModelValidations
                         updated_at: Time.current)
          self
        end

        private

        def provider_id_updates(incoming)
          ids = (provider_ids | Array(incoming).map(&:to_s).reject(&:empty?))
          return {} if ids == provider_ids

          { provider_message_ids: ids, provider_message_id: provider_message_id.presence || ids.first }
        end
      end
    end
  end
end
