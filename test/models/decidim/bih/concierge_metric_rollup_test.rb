# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require_relative "../../../../app/services/decidim/bih/concierge/dialogue/contracts"
require_relative "../../../../app/services/decidim/bih/concierge/answer_outcome"
require_relative "../../../../app/services/decidim/bih/concierge/dialogue/question_facet"

# The model inherits from Decidim::ApplicationRecord (needs a database). Its
# host-free contract — the bounded vocabularies and which validation macro
# enforces them — is checked here against a stand-in base class that records
# the class-macro calls; the database-backed behaviour (uniqueness, the
# latency-bucket/kind rule) is covered by the host's model test.
module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      class << self
        attr_reader :recorded_validations

        def table_name=(*); end

        def belongs_to(*); end

        def scope(*); end

        def validate(*); end

        def validates(*args)
          (@recorded_validations ||= []) << args
        end
      end
    end
    CONCIERGE_METRIC_ROLLUP_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../app/models/decidim/bih/concierge_metric_rollup"

module Decidim
  module Bih
    class ConciergeMetricRollupTest < Minitest::Test
      STAND_IN_BASE = Decidim.const_defined?(:CONCIERGE_METRIC_ROLLUP_TEST_DEFINED_APPLICATION_RECORD, false)

      def test_kinds_and_stage_vocabularies_are_fixed
        assert_equal %w(answer answer_detail read stage), ConciergeMetricRollup::KINDS
        assert_equal (["unknown"] + Decidim::Bih::Concierge::Dialogue::QuestionFacet::FACETS).sort, ConciergeMetricRollup::FACETS.sort
        assert_equal %w(understanding rendering), ConciergeMetricRollup::STAGES
        assert_equal %w(completed failed), ConciergeMetricRollup::STAGE_STATUSES
      end

      def test_latency_buckets_mirror_the_host_read_metrics_histogram
        assert_equal %w(10 25 50 100 250 500 1000 2500 5000 10000 30000 overflow), ConciergeMetricRollup::LATENCY_BUCKETS
      end

      def test_topics_and_labels_are_bounded_by_the_dialogue_contracts
        contracts = Decidim::Bih::Concierge::Dialogue::Contracts

        assert_equal contracts::TOPICS, ConciergeMetricRollup.topics_for("answer")
        assert_equal contracts::TOPICS, ConciergeMetricRollup.topics_for("read")
        assert_equal ConciergeMetricRollup::STAGES, ConciergeMetricRollup.topics_for("stage")
        assert_equal Decidim::Bih::Concierge::AnswerOutcome::OUTCOMES, ConciergeMetricRollup.labels_for("answer")
        assert_equal contracts::READ_STATUSES, ConciergeMetricRollup.labels_for("read")
        assert_equal ConciergeMetricRollup::STAGE_STATUSES, ConciergeMetricRollup.labels_for("stage")
        assert_equal [], ConciergeMetricRollup.labels_for("free_text")
      end

      def test_technical_failure_labels_are_a_subset_of_the_answer_outcomes
        outcomes = Decidim::Bih::Concierge::AnswerOutcome::OUTCOMES

        assert_equal %w(fallback error provider_unavailable busy), ConciergeMetricRollup::TECHNICAL_FAILURE_LABELS
        assert_empty ConciergeMetricRollup::TECHNICAL_FAILURE_LABELS - outcomes
      end

      def test_every_column_that_could_carry_text_is_an_inclusion_validation
        skip "real ActiveRecord loaded; validation macro not observable here" unless STAND_IN_BASE

        validated = ConciergeMetricRollup.recorded_validations.to_h { |args| [args.first, args.last] }

        assert_equal({ inclusion: { in: ConciergeMetricRollup::KINDS } }, validated.fetch(:kind))
        assert validated.fetch(:topic).fetch(:inclusion).fetch(:in).respond_to?(:call)
        assert validated.fetch(:label).fetch(:inclusion).fetch(:in).respond_to?(:call)
        assert_equal ConciergeMetricRollup::LATENCY_BUCKETS, validated.fetch(:latency_bucket).fetch(:inclusion).fetch(:in)
        assert_equal ConciergeMetricRollup::FACETS, validated.fetch(:facet).fetch(:inclusion).fetch(:in)
        assert_equal ConciergeMetricRollup::TRAFFIC_KINDS, validated.fetch(:traffic_kind).fetch(:inclusion).fetch(:in)
        assert_equal ConciergeMetricRollup::RELEASE_SHA_FORMAT, validated.fetch(:release_sha).fetch(:format).fetch(:with)
        assert_equal({ only_integer: true, greater_than_or_equal_to: 0 }, validated.fetch(:count).fetch(:numericality))
      end
    end
  end

  if const_defined?(:CONCIERGE_METRIC_ROLLUP_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:CONCIERGE_METRIC_ROLLUP_TEST_DEFINED_APPLICATION_RECORD)
  end
end
