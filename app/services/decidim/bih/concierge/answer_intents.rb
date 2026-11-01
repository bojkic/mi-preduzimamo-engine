# frozen_string_literal: true

module Decidim
  module Bih
    module Concierge
      # Bounded answer-intent labels used by feedback, aggregate usage metrics,
      # and admin analytics. Keep this list metadata-only; it must never contain
      # raw citizen text or free-form classifier output.
      module AnswerIntents
        VALUES = %w(
          account_linking budget city_event data_status donation fallback gazette goodwill help
          komsiluk_post komsiluk_read launch local_area_guidance participation_guidance
          moderation privacy report report_guidance safety service setup status unknown
          volunteer_guidance waste
        ).freeze
        DEFAULT = "unknown"

        def self.sanitize(value)
          intent = value.to_s
          VALUES.include?(intent) ? intent : DEFAULT
        end
      end
    end
  end
end
