# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"

module Decidim
  unless const_defined?(:ApplicationRecord, false)
    class ApplicationRecord
      def self.table_name=(*); end

      def self.belongs_to(*); end

      def self.has_one(*); end

      def self.has_many(*); end

      def self.validates(*); end

      def self.validate(*); end

      def self.before_validation(*); end

      def self.scope(*); end
    end
    COMMUNITY_CONTRIBUTION_TEST_DEFINED_APPLICATION_RECORD = true
  end
end

require_relative "../../../../app/models/decidim/bih/partner_project_submission"
require_relative "../../../../app/models/decidim/bih/project_donation_link"
require_relative "../../../../app/models/decidim/bih/contribution_need"
require_relative "../../../../app/models/decidim/bih/contribution_offer"

module Decidim
  if const_defined?(:COMMUNITY_CONTRIBUTION_TEST_DEFINED_APPLICATION_RECORD, false)
    remove_const(:ApplicationRecord)
    remove_const(:COMMUNITY_CONTRIBUTION_TEST_DEFINED_APPLICATION_RECORD)
  end

  module Bih
    class CommunityContributionPolicyTest < Minitest::Test
      def test_non_cash_need_types_do_not_duplicate_money_people_or_skills
        assert_equal %w(equipment materials space transport other), ContributionNeed::NEED_TYPES
        assert_equal BigDecimal("9999999999.99"), ContributionNeed::MAX_QUANTITY
        refute_includes ContributionNeed::NEED_TYPES, "cash"
        refute_includes ContributionNeed::NEED_TYPES, "people"
        refute_includes ContributionNeed::NEED_TYPES, "skills"
      end

      def test_submission_and_need_publication_states_are_explicit
        assert_equal %w(draft submitted changes_requested approved rejected),
                     PartnerProjectSubmission::REVIEW_STATUSES
        assert_equal %w(pending approved rejected), ContributionNeed::REVIEW_STATUSES
        assert_equal %w(open fulfilled cancelled), ContributionNeed::FULFILLMENT_STATUSES
      end

      def test_offer_confirmation_and_recognition_are_distinct_facts
        assert_equal %w(offered accepted declined withdrawn delivered confirmed), ContributionOffer::STATUSES
        assert_equal %w(accepted delivered confirmed), ContributionOffer::RESERVING_STATUSES

        offer = ContributionOffer.allocate
        offer.define_singleton_method(:status) { "confirmed" }
        offer.define_singleton_method(:recognized_at) { nil }
        offer.define_singleton_method(:partner_profile) { nil }

        assert offer.confirmed?
        refute offer.recognized?
        assert offer.personal?
      end

      def test_campaign_key_contract_is_provider_neutral_and_bounded
        assert_match ProjectDonationLink::CAMPAIGN_KEY_PATTERN, "community-project-42"
        assert_match ProjectDonationLink::CAMPAIGN_KEY_PATTERN, "legacy_campaign_42"
        refute_match ProjectDonationLink::CAMPAIGN_KEY_PATTERN, "https://provider.example/42"
        assert_equal 100, ProjectDonationLink::MAX_CAMPAIGN_KEY_LENGTH
      end
    end
  end
end
