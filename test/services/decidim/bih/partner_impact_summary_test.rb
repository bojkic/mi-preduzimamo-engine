# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/partner_impact_summary"

module Decidim
  module Bih
    class PartnerImpactSummaryTest < Minitest::Test
      class Relation
        def initialize(count:, fulfilled_count: nil, sum: nil, distinct_count: nil)
          @count = count
          @fulfilled_count = fulfilled_count
          @sum = sum
          @distinct_count = distinct_count
        end

        def where(*) = self

        def count(*) = @count

        def fulfilled = self.class.new(count: @fulfilled_count)

        def sum(*) = @sum

        def distinct = self

        attr_reader :distinct_count
      end

      class LogRelation < Relation
        def count(*) = distinct_count
      end

      class QueryClass
        class << self
          attr_accessor :relation
          attr_reader :recognized_called, :where_calls
        end

        def self.approved = relation

        def self.confirmed = relation

        def self.recognized
          @recognized_called = true
          relation
        end

        def self.publicly_visible = relation

        def self.where(*arguments)
          @where_calls ||= []
          @where_calls << arguments
          relation
        end
      end

      def test_returns_only_aggregate_impact_and_derived_recognition_labels
        submission_class = Class.new(QueryClass)
        need_class = Class.new(QueryClass)
        offer_class = Class.new(QueryClass)
        opportunity_class = Class.new(QueryClass)
        log_class = Class.new(QueryClass)
        submission_class.relation = Relation.new(count: 1)
        need_class.relation = Relation.new(count: 3, fulfilled_count: 2)
        offer_class.relation = Relation.new(count: 4)
        opportunity_class.relation = Relation.new(count: 2)
        log_class.relation = LogRelation.new(count: 5, sum: 12, distinct_count: 5)

        profile = Struct.new(:organization).new(Object.new)
        result = PartnerImpactSummary.call(
          partner_profile: profile,
          submission_class:,
          need_class:,
          offer_class:,
          opportunity_class:,
          log_class:
        )

        assert_equal 1, result.approved_projects_count
        assert_equal 3, result.approved_needs_count
        assert_equal 2, result.fulfilled_needs_count
        assert_equal 4, result.confirmed_offers_count
        assert offer_class.recognized_called
        assert_equal 2, result.hosted_volunteer_opportunities_count
        assert_equal 12, result.approved_volunteer_hours
        assert_equal 5, result.distinct_volunteer_participants_count
        assert_equal [:project_initiator, :community_partner, :volunteer_host, :repeat_partner], result.recognition_labels
        assert result.frozen?
        assert result.recognition_labels.frozen?
      end

      def test_cancelled_and_inactive_approved_shifts_remain_in_lifetime_impact
        submission_class = Class.new(QueryClass)
        need_class = Class.new(QueryClass)
        offer_class = Class.new(QueryClass)
        opportunity_class = Class.new(QueryClass)
        log_class = Class.new(QueryClass)
        submission_class.relation = Relation.new(count: 0)
        need_class.relation = Relation.new(count: 0, fulfilled_count: 0)
        offer_class.relation = Relation.new(count: 0)
        opportunity_class.relation = Relation.new(count: 2)
        log_class.relation = LogRelation.new(count: 3, sum: 9, distinct_count: 3)
        organization = Object.new
        profile = Struct.new(:organization).new(organization)

        result = PartnerImpactSummary.call(
          partner_profile: profile,
          submission_class:,
          need_class:,
          offer_class:,
          opportunity_class:,
          log_class:
        )

        assert_equal 2, result.hosted_volunteer_opportunities_count
        assert_equal 9, result.approved_volunteer_hours
        assert_equal 3, result.distinct_volunteer_participants_count
        assert_includes opportunity_class.where_calls,
                        [{ organization:, partner_profile: profile, review_status: "approved" }]
      end
    end
  end
end
