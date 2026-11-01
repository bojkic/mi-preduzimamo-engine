# frozen_string_literal: true

module Decidim
  module Bih
    # Daily metadata-only usage counters for the concierge bot.
    #
    # Privacy contract: rows are aggregate numeric counters only. They never
    # store prompts, replies, session digests, sender ids, IP addresses, user
    # agents, tokens, or provider payloads.
    class ConciergeUsageAggregate < Decidim::ApplicationRecord
      self.table_name = "decidim_bih_concierge_usage_aggregates"

      # "viber" is the dormant Viber Bot transport; "viber_bm" is Viber Business
      # Messages, the live two-way channel. Both are kept so historical Bot rows
      # stay readable in analytics.
      CHANNELS = %w(web_chat viber viber_bm whatsapp messenger instagram).freeze
      OUTCOMES = %w(success blank fallback error).freeze
      DIALOGUE_COUNTER_COLUMNS = %w(
        resolution_answered_count resolution_clarification_count
        resolution_handoff_count resolution_draft_count
        resolution_submitted_count resolution_cancelled_count
        resolution_unsupported_count resolution_source_unavailable_count
        resolution_delivery_failed_count resolution_safety_guidance_count handoff_offered_count
        handoff_completed_count grounded_answer_count action_receipt_count
      ).freeze

      belongs_to :organization,
                 class_name: "Decidim::Organization",
                 foreign_key: "decidim_organization_id"

      validates :bucket_on, presence: true
      validates :channel, inclusion: { in: CHANNELS }
      validates :outcome, inclusion: { in: OUTCOMES }
      validates :answer_intent, inclusion: { in: Decidim::Bih::Concierge::AnswerIntents::VALUES }
      validates :locale, presence: true, length: { maximum: 16 }
      validates :requests_count, :message_length_total, :reply_length_total,
                :quick_replies_total, :sticker_count,
                numericality: { greater_than_or_equal_to: 0, only_integer: true }
      validate :dialogue_counters_are_nonnegative_integers

      scope :for_organization, ->(organization) { where(organization:) }

      private

      # Keep the model bootable before the additive outcome migration. The
      # database check remains authoritative once these columns are installed.
      def dialogue_counters_are_nonnegative_integers
        DIALOGUE_COUNTER_COLUMNS.each do |column|
          next unless has_attribute?(column)

          value = self[column]
          errors.add(column, :not_a_number) unless value.is_a?(Integer) && value >= 0
        end
      end
    end
  end
end
