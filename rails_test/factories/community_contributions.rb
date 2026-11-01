# frozen_string_literal: true

FactoryBot.define do
  sequence(:bih_partner_slug) { |n| "rails-partner-#{n}" }
  sequence(:bih_campaign_key) { |n| "rails-community-project-#{n}" }

  factory :bih_partner_profile, class: "Decidim::Bih::PartnerProfile" do
    organization
    display_name { "Rails partner #{generate(:bih_partner_slug)}" }
    slug { generate(:bih_partner_slug) }
    kind { "business" }
    verification_status { "verified" }
    public_description { "Verified partner used by the generated-host domain tests." }
  end

  factory :bih_partner_membership, class: "Decidim::Bih::PartnerMembership" do
    organization
    partner_profile { association(:bih_partner_profile, organization:) }
    user { association(:user, :confirmed, organization:) }
    role { "owner" }
    status { "accepted" }
    accepted_at { Time.current }
  end

  factory :bih_partner_project_submission, class: "Decidim::Bih::PartnerProjectSubmission" do
    organization
    partner_profile { association(:bih_partner_profile, organization:) }
    representative { association(:user, :confirmed, organization:) }
    title { "Community park renewal" }
    description { "Repair benches and improve safe public access." }
    budget_amount { 5_000 }
    address { "City park" }
    review_status { "draft" }

    before(:create) do |submission|
      Decidim::Bih::PartnerMembership.find_or_create_by!(
        organization: submission.organization,
        partner_profile: submission.partner_profile,
        user: submission.representative
      ) do |membership|
        membership.role = "content_editor"
        membership.status = "accepted"
        membership.accepted_at = Time.current
      end
    end

    trait :submitted do
      review_status { "submitted" }
      submitted_at { Time.current }
    end

    trait :approved do
      transient do
        approved_project do
          component = association(:budgets_component, organization:)
          budget = association(:budget, component:)
          association(:project, budget:)
        end
      end

      review_status { "approved" }
      submitted_at { 1.day.ago }
      reviewed_at { Time.current }
      project { approved_project }
    end
  end

  factory :bih_project_donation_link, class: "Decidim::Bih::ProjectDonationLink" do
    project
    organization { project.organization }
    campaign_key { generate(:bih_campaign_key) }
    active { true }
  end

  factory :bih_contribution_need, class: "Decidim::Bih::ContributionNeed" do
    organization
    partner_profile { association(:bih_partner_profile, organization:) }
    author { association(:user, :confirmed, organization:) }
    need_type { "equipment" }
    title { "Ten garden tools" }
    description { "Reusable tools for scheduled community maintenance." }
    quantity { 10 }
    unit { "pieces" }
    review_status { "pending" }
    fulfillment_status { "open" }

    before(:create) do |need|
      Decidim::Bih::PartnerMembership.find_or_create_by!(
        organization: need.organization,
        partner_profile: need.partner_profile,
        user: need.author
      ) do |membership|
        membership.role = "volunteer_coordinator"
        membership.status = "accepted"
        membership.accepted_at = Time.current
      end
    end

    trait :approved do
      review_status { "approved" }
      reviewed_at { Time.current }
      published_at { Time.current }
    end

    trait :fulfilled do
      approved
      fulfillment_status { "fulfilled" }
      closed_at { Time.current }
    end
  end

  factory :bih_contribution_offer, class: "Decidim::Bih::ContributionOffer" do
    contribution_need { association(:bih_contribution_need, :approved) }
    organization { contribution_need.organization }
    contributor { association(:user, :confirmed, organization:) }
    quantity { 1 }
    status { "offered" }

    trait :confirmed do
      status { "confirmed" }
      confirmed_at { Time.current }
    end

    trait :from_partner do
      partner_profile { association(:bih_partner_profile, organization:) }

      before(:create) do |offer|
        Decidim::Bih::PartnerMembership.find_or_create_by!(
          organization: offer.organization,
          partner_profile: offer.partner_profile,
          user: offer.contributor
        ) do |membership|
          membership.role = "volunteer_coordinator"
          membership.status = "accepted"
          membership.accepted_at = Time.current
        end
      end
    end
  end
end
