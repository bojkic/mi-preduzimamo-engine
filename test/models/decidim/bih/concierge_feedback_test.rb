# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"

# The model inherits from Decidim::ApplicationRecord (needs a database). To
# check its host-free contract — the accepted value vocabulary and that the
# vocabulary is enforced by an inclusion validation — provide a stand-in base
# class that records the class-macro calls. It is defined only when the real
# constant is absent and removed again right after the model loads, so it can
# never leak a too-thin base class into other test files.
module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      class << self
        attr_reader :recorded_validations

        def table_name=(*); end

        def belongs_to(*); end

        def scope(*); end

        def validates(*args)
          (@recorded_validations ||= []) << args
        end
      end
    end
    CONCIERGE_FEEDBACK_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../app/models/decidim/bih/concierge_feedback"

module Decidim
  module Bih
    class ConciergeFeedbackTest < Minitest::Test
      STAND_IN_BASE = Decidim.const_defined?(:CONCIERGE_FEEDBACK_TEST_DEFINED_APPLICATION_RECORD, false)

      def test_share_question_joins_the_two_ratings_as_an_accepted_value
        assert_equal %w(helpful not_helpful share_question), ConciergeFeedback::VALUES
      end

      def test_the_value_vocabulary_is_enforced_by_an_inclusion_validation
        skip "real ActiveRecord loaded; validation macro not observable here" unless STAND_IN_BASE

        validation = ConciergeFeedback.recorded_validations.find { |args| args.first == :value }
        assert_equal [:value, { inclusion: { in: ConciergeFeedback::VALUES } }], validation
      end

      def test_reply_ids_stay_uuid_shaped
        assert_match ConciergeFeedback::REPLY_ID_FORMAT, "6f1d2c3a-1b2c-4d5e-8f90-1234567890ab"
        refute_match ConciergeFeedback::REPLY_ID_FORMAT, "share_question"
      end
    end
  end

  if const_defined?(:CONCIERGE_FEEDBACK_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:CONCIERGE_FEEDBACK_TEST_DEFINED_APPLICATION_RECORD)
  end
end
