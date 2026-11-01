# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class CommunityContributionDomainTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @reviewer = create(:user, :admin, :confirmed, organization: @organization)
        end

        test "factories persist moderated submissions needs and offers with tenant boundaries" do
          submission = create(:bih_partner_project_submission, :submitted, organization: @organization)
          need = create(
            :bih_contribution_need,
            :approved,
            organization: @organization,
            partner_profile: submission.partner_profile
          )
          offer = create(:bih_contribution_offer, contribution_need: need, organization: @organization)

          assert submission.submitted?
          assert need.approved?
          assert need.open?
          assert offer.offered?
          assert_equal @organization, submission.representative.organization
          assert_equal @organization, offer.contributor.organization
        end

        test "need quantity is bounded to the database decimal precision" do
          need = build(
            :bih_contribution_need,
            organization: @organization,
            quantity: BigDecimal("10000000000")
          )

          refute need.valid?
          assert need.errors[:quantity].present?
        end

        test "canonical donation link rejects a project from another organization" do
          project = create(:project)
          link = Decidim::Bih::ProjectDonationLink.new(
            organization: @organization,
            project:,
            campaign_key: "wrong-tenant-project"
          )

          refute link.valid?
          assert link.errors[:project].present?
        end

        test "offer recognition awards a personal citizen once and not a partner representative" do
          need = create(:bih_contribution_need, :approved, organization: @organization)
          citizen_offer = create(:bih_contribution_offer, :confirmed, contribution_need: need)
          partner_offer = create(:bih_contribution_offer, :confirmed, :from_partner, contribution_need: need)

          assert_equal :ok, ManageContributionOffer.call(offer: citizen_offer, actor: @reviewer, action: :recognize)
          assert_equal :already, ManageContributionOffer.call(offer: citizen_offer.reload, actor: @reviewer, action: :recognize)
          assert_equal 1, Goodwill::Transaction.where(idempotency_key: "contribution_offer:#{citizen_offer.id}").count

          assert_equal :ok, ManageContributionOffer.call(offer: partner_offer, actor: @reviewer, action: :recognize)
          assert_equal 0, Goodwill::Transaction.where(idempotency_key: "contribution_offer:#{partner_offer.id}").count
        end

        test "blocked legacy owner prevents project and need publication" do
          legacy_owner = create(:user, :confirmed, organization: @organization)
          profile = create(
            :bih_partner_profile,
            organization: @organization,
            legacy_user_group: legacy_owner
          )
          submission = create(
            :bih_partner_project_submission,
            :submitted,
            organization: @organization,
            partner_profile: profile
          )
          need = create(:bih_contribution_need, organization: @organization, partner_profile: profile)
          legacy_owner.update!(blocked: true, blocked_at: Time.current, extended_data: {})

          assert_equal :invalid,
                       ApprovePartnerProjectSubmission.call(
                         submission,
                         reviewer: @reviewer,
                         campaign_key: "blocked-legacy-owner"
                       )
          assert_equal :invalid, ApproveContributionNeed.call(need, reviewer: @reviewer)
        end

        test "a public profile keeps its last manager after suspension" do
          profile = create(:bih_partner_profile, organization: @organization)
          membership = create(
            :bih_partner_membership,
            organization: @organization,
            partner_profile: profile,
            role: "owner"
          )
          create(
            :bih_contribution_need,
            :approved,
            organization: @organization,
            partner_profile: profile,
            author: membership.user
          )

          membership.assign_attributes(role: "content_editor")
          refute membership.save
          assert membership.errors[:base].present?

          membership.reload.assign_attributes(status: "revoked", revoked_at: Time.current)
          refute membership.save
          assert membership.errors[:base].present?

          profile.update!(verification_status: "suspended")
          membership.reload.assign_attributes(status: "revoked", revoked_at: Time.current)
          refute membership.save
          assert membership.errors[:base].present?
          assert_equal "accepted", membership.reload.status
        end

        test "a replacement volunteer manager permits revocation with an open need" do
          profile = create(:bih_partner_profile, organization: @organization)
          owner = create(
            :bih_partner_membership,
            organization: @organization,
            partner_profile: profile,
            role: "owner"
          )
          create(
            :bih_contribution_need,
            :approved,
            organization: @organization,
            partner_profile: profile,
            author: owner.user
          )
          create(
            :bih_partner_membership,
            organization: @organization,
            partner_profile: profile,
            role: "manager"
          )

          owner.update!(status: "revoked", revoked_at: Time.current)
          assert_equal "revoked", owner.reload.status
        end

        test "need approval fails when its volunteer manager was revoked before publication" do
          profile = create(:bih_partner_profile, organization: @organization)
          membership = create(
            :bih_partner_membership,
            organization: @organization,
            partner_profile: profile,
            role: "owner"
          )
          need = create(
            :bih_contribution_need,
            organization: @organization,
            partner_profile: profile,
            author: membership.user
          )

          # Simulate a legacy or externally-corrupted row. Normal model writes
          # reject revoking the last accepted manager before this point.
          # rubocop:disable Rails/SkipsModelValidations
          membership.update_columns(status: "revoked", revoked_at: Time.current, updated_at: Time.current)
          # rubocop:enable Rails/SkipsModelValidations

          assert_equal :invalid, ApproveContributionNeed.call(need, reviewer: @reviewer)
          assert need.reload.pending_review?
        end

        test "historical rows remain reviewable after staff revocation or profile suspension" do
          submission = create(:bih_partner_project_submission, :submitted, organization: @organization)
          submission.partner_profile.memberships.find_by!(user: submission.representative).update!(
            status: "revoked",
            revoked_at: Time.current
          )
          submission.partner_profile.update!(verification_status: "suspended")

          assert_equal :ok,
                       RejectPartnerProjectSubmission.call(
                         submission,
                         reviewer: @reviewer,
                         reason: "No longer in scope"
                       )
          assert submission.rejected?

          need = create(:bih_contribution_need, organization: @organization)
          need.partner_profile.update!(verification_status: "suspended")
          need.partner_profile.memberships.find_by!(user: need.author).update!(
            status: "revoked",
            revoked_at: Time.current
          )

          assert_equal :invalid, ApproveContributionNeed.call(need, reviewer: @reviewer)
          assert_equal :ok,
                       RejectContributionNeed.call(
                         need,
                         reviewer: @reviewer,
                         reason: "Profile suspended before review"
                       )
          assert need.rejected?

          closable_need = create(:bih_contribution_need, :approved, organization: @organization)
          closable_need.partner_profile.update!(verification_status: "suspended")

          assert_equal :ok, CancelContributionNeed.call(need: closable_need, actor: closable_need.author)
          assert closable_need.cancelled?

          offer_need = create(:bih_contribution_need, :approved, organization: @organization)
          offer = create(:bih_contribution_offer, :from_partner, contribution_need: offer_need, status: "accepted")
          offer.partner_profile.memberships.find_by!(user: offer.contributor).update!(
            status: "revoked",
            revoked_at: Time.current
          )
          offer.partner_profile.update!(verification_status: "suspended")

          assert_equal :ok,
                       ManageContributionOffer.call(
                         offer:,
                         actor: offer_need.author,
                         action: :decline,
                         reason: "Another offer fits better"
                       )
          assert offer.declined?
        end

        test "offered proposals do not reserve capacity and acceptance does so atomically" do
          need = create(:bih_contribution_need, :approved, organization: @organization, quantity: 10)
          first = create(:bih_contribution_offer, contribution_need: need, quantity: 8)
          second = create(:bih_contribution_offer, contribution_need: need, quantity: 8)

          assert_equal 10, need.remaining_quantity
          assert_equal :ok, ManageContributionOffer.call(offer: first, actor: need.author, action: :accept)
          assert_equal 2, need.remaining_quantity
          assert_equal :invalid, ManageContributionOffer.call(offer: second, actor: need.author, action: :accept)
          assert second.reload.offered?

          assert_equal :ok, ManageContributionOffer.call(offer: first.reload, actor: need.author, action: :decline)
          assert_equal 10, need.remaining_quantity
        end

        test "a suspended receiving profile cannot receive new offers but existing offers remain manageable" do
          need = create(:bih_contribution_need, :approved, organization: @organization, quantity: 2)
          existing = create(:bih_contribution_offer, contribution_need: need, quantity: 1)
          new_contributor = create(:user, :confirmed, organization: @organization)
          need.partner_profile.update!(verification_status: "suspended")

          result, offer = CreateContributionOffer.call(
            need:,
            contributor: new_contributor,
            quantity: 1
          )
          direct_offer = build(
            :bih_contribution_offer,
            contribution_need: need,
            contributor: new_contributor,
            quantity: 1
          )

          assert_equal :invalid, result
          assert_nil offer
          refute direct_offer.valid?
          assert direct_offer.errors[:contribution_need].present?
          assert_equal :invalid,
                       ManageContributionOffer.call(
                         offer: existing,
                         actor: need.author,
                         action: :accept
                       )
          assert existing.reload.offered?
          assert_equal :ok,
                       ManageContributionOffer.call(
                         offer: existing,
                         actor: need.author,
                         action: :decline,
                         reason: "Need is no longer public"
                       )
        end

        test "a blocked legacy owner prevents a partner offer" do
          need = create(:bih_contribution_need, :approved, organization: @organization, quantity: 2)
          contributor = create(:user, :confirmed, organization: @organization)
          legacy_owner = create(:user, :confirmed, organization: @organization)
          blocked_profile = create(
            :bih_partner_profile,
            organization: @organization,
            legacy_user_group: legacy_owner
          )
          legacy_owner.update!(blocked: true, blocked_at: Time.current, extended_data: {})

          result, offer = CreateContributionOffer.call(
            need:,
            contributor:,
            quantity: 1,
            partner_profile: blocked_profile
          )
          direct_offer = build(
            :bih_contribution_offer,
            contribution_need: need,
            contributor:,
            partner_profile: blocked_profile,
            quantity: 1
          )

          assert_equal :forbidden, result
          assert_nil offer
          refute direct_offer.valid?
          assert direct_offer.errors[:partner_profile].present?
        end

        test "public volunteering keeps profile-less opportunities but hides a suspended partner host" do
          profile = create(:bih_partner_profile, organization: @organization)
          profile_less = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            title: "LFBN community shift",
            active: true,
            review_status: "approved"
          )
          partner_hosted = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            partner_profile: profile,
            title: "Partner-hosted shift",
            active: true,
            review_status: "approved"
          )

          assert_includes Decidim::Bih::VolunteerOpportunity.publicly_visible, profile_less
          assert_includes Decidim::Bih::VolunteerOpportunity.publicly_visible, partner_hosted

          profile.update!(verification_status: "suspended")

          assert_includes Decidim::Bih::VolunteerOpportunity.publicly_visible, profile_less
          assert_not_includes Decidim::Bih::VolunteerOpportunity.publicly_visible, partner_hosted
          assert_includes Decidim::Bih::VolunteerOpportunity.active, partner_hosted
        end

        test "suspension blocks opportunity approval but preserves rejection and series cancellation" do
          profile = create(:bih_partner_profile, organization: @organization)
          pending = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            partner_profile: profile,
            title: "Pending partner shift",
            active: false,
            review_status: "pending"
          )
          series_shift = Decidim::Bih::VolunteerOpportunity.create!(
            organization: @organization,
            partner_profile: profile,
            title: "Future partner shift",
            active: true,
            review_status: "approved",
            starts_at: 1.day.from_now,
            series_key: "suspended-partner-series",
            series_position: 1,
            series_total: 1
          )

          profile.update!(verification_status: "suspended")

          assert_equal :invalid, ApproveVolunteerOpportunity.call(pending, reviewer: @reviewer)
          assert_equal :ok,
                       RejectVolunteerOpportunity.call(
                         pending,
                         reviewer: @reviewer,
                         reason: "Partner participation paused"
                       )
          result = VolunteerSeriesUpdate.new(
            organization: @organization,
            series_key: series_shift.series_key,
            actor: @reviewer,
            cancel: true,
            cancellation_reason: "Partner participation paused"
          ).call

          assert_equal :updated, result.status
          assert series_shift.reload.cancelled?
        end

        test "a linked opportunity requires the same approved partner project at assignment" do
          submission = create(:bih_partner_project_submission, :approved, organization: @organization)
          link = create(
            :bih_project_donation_link,
            organization: @organization,
            project: submission.project
          )
          another_profile = create(:bih_partner_profile, organization: @organization)
          linked = Decidim::Bih::VolunteerOpportunity.new(
            organization: @organization,
            partner_profile: submission.partner_profile,
            budget_project: submission.project,
            title: "Project volunteer shift",
            active: true,
            review_status: "approved"
          )
          misattributed = linked.dup
          misattributed.partner_profile = another_profile

          assert linked.valid?
          refute misattributed.valid?
          assert misattributed.errors[:budget_project].present?

          linked.save!
          link.update!(active: false)
          submission.partner_profile.update!(verification_status: "suspended")
          linked.update!(active: false, cancellation_reason: "Participation paused", cancelled_at: Time.current)
          assert linked.reload.cancelled?
        end

        test "deactivating a project donation link does not freeze an existing need fulfillment" do
          submission = create(:bih_partner_project_submission, :approved, organization: @organization)
          link = create(
            :bih_project_donation_link,
            organization: @organization,
            project: submission.project
          )
          need = create(
            :bih_contribution_need,
            :approved,
            organization: @organization,
            partner_profile: submission.partner_profile,
            project: submission.project,
            quantity: 1
          )
          offer = create(
            :bih_contribution_offer,
            contribution_need: need,
            quantity: 1,
            status: "delivered",
            delivered_at: Time.current
          )

          link.update!(active: false)

          assert_equal :ok, ManageContributionOffer.call(offer:, actor: need.author, action: :confirm)
          assert need.reload.fulfilled?
        end
      end
    end
  end
end
