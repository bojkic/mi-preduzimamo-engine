# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Matched-giving request (R13): a MUTABLE status record — deliberately NOT
      # in the append-only ledger — capturing an admin's intent to match a
      # group/organization's received goodwill with a real-world micro-grant.
      #
      # The actual grant stays a MANUAL LFBN bookkeeping step (no Odoo write
      # integration); this model only records the request and its decision
      # (pending → approved/rejected). Surfaced in the admin goodwill dashboard.
      class MatchRequest < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_goodwill_match_requests"

        STATUSES = %w(pending approved rejected).freeze
        PAYOUT_STATUSES = %w(unpaid paid).freeze
        MAX_PAYOUT_NOTE_LENGTH = 2_000

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        belongs_to :owner, polymorphic: true

        belongs_to :created_by, class_name: "Decidim::User", optional: true
        belongs_to :decided_by, class_name: "Decidim::User", optional: true
        belongs_to :payout_recorded_by, class_name: "Decidim::User", optional: true

        validates :status, inclusion: { in: STATUSES }
        validates :payout_status, inclusion: { in: PAYOUT_STATUSES }
        validates :points, numericality: { only_integer: true, greater_than: 0 }
        validates :payout_amount_minor_units,
                  numericality: { only_integer: true, greater_than: 0 },
                  allow_nil: true
        validates :payout_currency, length: { is: 3 }, allow_blank: false
        validates :payout_reference, length: { maximum: 255 }, allow_blank: true
        validates :payout_note, length: { maximum: MAX_PAYOUT_NOTE_LENGTH }, allow_blank: true
        validate :owner_belongs_to_organization
        validate :paid_payout_has_reference
        validate :paid_payout_has_amount
        validate :paid_payout_has_paid_on
        validate :paid_payout_is_approved

        scope :pending, -> { where(status: "pending") }
        scope :approved, -> { where(status: "approved") }
        scope :rejected, -> { where(status: "rejected") }
        scope :unpaid, -> { where(payout_status: "unpaid") }
        scope :paid, -> { where(payout_status: "paid") }

        def pending?
          status == "pending"
        end

        def approved?
          status == "approved"
        end

        def paid?
          payout_status == "paid"
        end

        # Stamp the admin decision. Returns true on success. No-op (false) if the
        # request is no longer pending, so a double-click can't re-decide it.
        def decide!(status, by:)
          return false unless by && by.organization == organization
          return false unless %w(approved rejected).include?(status)

          with_lock do
            return false unless pending?

            update!(status:, decided_by: by, decided_at: Time.current)
            yield if block_given?
          end
          true
        end

        # Records the manual LFBN/Odoo/bookkeeping payout that follows an approved
        # match request. The Goodwill ledger remains untouched; this is an
        # operational audit marker for the real-world grant handover.
        def record_payout!(by:, reference:, amount_minor_units:, **options)
          return false unless by && by.organization == organization

          with_lock do
          return false unless approved?
          return false if paid?

          reference = reference.to_s.strip
          raw_amount = amount_minor_units.to_s
          return false unless raw_amount.match?(/\A[1-9]\d{0,11}\z/)

          amount_minor_units = Integer(raw_amount, 10)
          currency = options.fetch(:currency, "BAM").to_s.strip.upcase.presence || "BAM"
          paid_on = options[:paid_on].presence || Date.current
          note = options[:note].to_s.strip.presence
          return false if reference.blank?
          return false unless amount_minor_units.positive?

          now = Time.current
          event = {
            "status" => "paid",
            "at" => now.utc.iso8601,
            "by_id" => by&.id,
            "amount_minor_units" => amount_minor_units,
            "currency" => currency,
            "paid_on" => paid_on.to_s,
            "reference" => reference,
            "note" => note
          }.compact
          self.payout_status = "paid"
          self.payout_amount_minor_units = amount_minor_units
          self.payout_currency = currency
          self.payout_reference = reference
          self.payout_note = note
          self.payout_paid_on = paid_on
          self.payout_recorded_by = by
          self.payout_recorded_at = now
          self.metadata = metadata.merge(
            "payout_events" => payout_events(event)
          )
          saved = save
          yield if saved && block_given?
          saved
          end
        end

        private

        def payout_events(event)
          Array(metadata["payout_events"]) + [event]
        end

        def owner_belongs_to_organization
          return if owner.blank? || organization.blank?
          return unless owner.respond_to?(:organization)
          return if owner.organization == organization

          errors.add(:owner, :invalid)
        end

        def paid_payout_has_reference
          return unless paid? && payout_reference.blank?

          errors.add(:payout_reference, :blank)
        end

        def paid_payout_has_amount
          return unless paid? && payout_amount_minor_units.blank?

          errors.add(:payout_amount_minor_units, :blank)
        end

        def paid_payout_has_paid_on
          return unless paid? && payout_paid_on.blank?

          errors.add(:payout_paid_on, :blank)
        end

        def paid_payout_is_approved
          return unless paid? && !approved?

          errors.add(:payout_status, :invalid)
        end
      end
    end
  end
end
