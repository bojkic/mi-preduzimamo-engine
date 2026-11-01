# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Public organization-admin command for requests that require operator
      # review before any points move.
      class CreateOrganizationSpendingRequest < Decidim::Command
        def initialize(actor, partner_profile_id, attributes)
          @actor = actor
          @partner_profile_id = partner_profile_id
          @attributes = attributes || {}
        end

        def call
          return broadcast(:invalid, nil) if actor.blank?

          profile = source_profile
          return broadcast(:invalid, nil) if profile.nil?
          return broadcast(:forbidden) unless finance_manager?(profile)

          request = build_request(profile)
          return broadcast(:insufficient) if request.points.to_i > available_balance(profile)

          request.save!
          broadcast(:ok, request)
        rescue ActiveRecord::RecordInvalid => e
          broadcast(:invalid, e.record)
        end

        private

        attr_reader :actor, :partner_profile_id, :attributes

        def source_profile
          @source_profile ||= Decidim::Bih::PartnerProfile
                              .goodwill_eligible
                              .where(organization: actor.organization)
                              .find_by(id: partner_profile_id)
        end

        def finance_manager?(profile)
          profile.memberships.accepted.exists?(
            decidim_user_id: actor.id,
            role: Decidim::Bih::PartnerMembership::FINANCE_ROLES
          )
        end

        def build_request(profile)
          OrganizationSpendingRequest.new(
            organization: actor.organization,
            source_partner_profile: profile,
            target_partner_profile: target_profile(profile),
            requested_by: actor,
            request_type: request_type,
            points: attributes[:points].to_s.to_i,
            category: category,
            reward_title: clean(attributes[:reward_title], OrganizationSpendingRequest::MAX_REWARD_TITLE_LENGTH),
            reward_description: clean(attributes[:reward_description], OrganizationSpendingRequest::MAX_REWARD_DESCRIPTION_LENGTH),
            reward_stock: positive_integer(attributes[:reward_stock]),
            reward_cost: positive_integer(attributes[:reward_cost])
          )
        end

        def target_profile(profile)
          return nil unless request_type == "inter_org_support"

          Decidim::Bih::PartnerProfile
            .goodwill_eligible
            .where(organization: actor.organization)
            .where.not(id: profile.id)
            .find_by(id: attributes[:target_partner_profile_id])
        end

        def request_type
          value = attributes[:request_type].to_s
          value.presence_in(OrganizationSpendingRequest::REQUEST_TYPES) || "inter_org_support"
        end

        def category
          allowed = if request_type == "reward_sponsorship"
                      OrganizationSpendingRequest::REWARD_CATEGORIES
                    else
                      OrganizationSpendingRequest::INTER_ORG_CATEGORIES
                    end
          attributes[:category].to_s.presence_in(allowed) || allowed.first
        end

        def positive_integer(value)
          number = value.to_s.to_i
          number.positive? ? number : nil
        end

        def clean(value, max_length)
          value.to_s.strip.presence&.truncate(max_length, omission: "")
        end

        def available_balance(profile)
          Ledger.new.account_for(PartnerOwner.owner_for(profile)).balance
        end
      end
    end
  end
end
