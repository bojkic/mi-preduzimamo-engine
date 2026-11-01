# frozen_string_literal: true

require_relative "../../text"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # A question about the meaning of coverage, not a claim that any
        # household has lost service. Never interprets reports or commands.
        module UtilityScopeQuestion
          TOPICS = %w(water electricity heating).freeze
          LOCAL = /\A(?:znaci li to da|da li to znaci da) (?:je svaka kuca|su sve kuce)(?: u [a-z][a-z -]{0,70})? bez (?:vode|struje|grijanja)\z/
          ENGLISH = /\Adoes that mean (?:every house|all houses)(?: in [a-z][a-z -]{0,70})? (?:has|have) no (?:water|electricity|heating)\z/

          def self.match?(text, topic:)
            return false unless TOPICS.include?(topic) && text.is_a?(String) && text.length <= 160

            folded = Text.fold(text)
            LOCAL.match?(folded) || ENGLISH.match?(folded)
          end
        end
      end
    end
  end
end
