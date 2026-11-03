# frozen_string_literal: true

require "test_helper"
require "decidim/budgets/test/factories"

module Decidim
  module Bih
    module RailsHarness
      class CommunityContributionsSurfaceTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @content_editor = FactoryBot.create(:user, :confirmed, organization: @organization)
          @volunteer_coordinator = FactoryBot.create(:user, :confirmed, organization: @organization)
          @profile = create_partner_profile!("surface-partner")
          create_membership!(@content_editor, "content_editor")
          create_membership!(@volunteer_coordinator, "volunteer_coordinator")
        end

        test "legacy participatory-budget project stays off the support catalog and preserves native interactions" do
          project = create_visible_project!("Legacy public project")
          Decidim::Bih::ProjectDonationLink.create!(
            organization: @organization,
            project:,
            campaign_key: "legacy-public-project",
            active: true
          )

          get public_path("projekti")
          assert_response :success
          assert_not_includes response.body, "Legacy public project"

          get public_path("projekti/#{project.id}")
          assert_redirected_to native_project_path(project), status: :moved_permanently
          follow_redirect!
          assert_response :success
          assert_includes response.body, 'id="comments"'
        end

        test "suspended partner leaves approved project transparency public but removes active discovery" do
          project = create_support_project!("Moderated hidden project")
          submission = Decidim::Bih::PartnerProjectSubmission.create!(
            organization: @organization,
            partner_profile: @profile,
            representative: @content_editor,
            project:,
            title: "Moderated hidden project",
            description: "Approved project that must follow current partner visibility.",
            budget_amount: 5_000,
            review_status: "approved",
            submitted_at: 2.days.ago,
            reviewed_at: 1.day.ago
          )
          Decidim::Bih::ProjectDonationLink.create!(
            organization: @organization,
            project:,
            campaign_key: "moderated-hidden-project",
            active: true
          )
          assert submission.persisted?

          @profile.update!(verification_status: "suspended", verified_at: nil)

          get public_path("projekti")
          assert_response :success
          assert_not_includes response.body, "Moderated hidden project"

          get public_path("projekti/#{project.id}")
          assert_response :success
          assert_includes response.body, "Moderated hidden project"
          assert_includes response.body, I18n.t(
            "decidim.bih.community_projects.show.participation_paused_note",
            locale: @organization.default_locale
          )
        end

        test "project and non-cash need submissions use distinct accepted role gates" do
          sign_in @content_editor
          assert_difference -> { Decidim::Bih::PartnerProjectSubmission.where(review_status: "submitted").count }, 1 do
            post public_path("projekti"), params: project_submission_params
          end
          assert_response :redirect

          assert_no_difference "Decidim::Bih::ContributionNeed.count" do
            post public_path("volontiranje/potrebe"), params: contribution_need_params
          end
          assert_response :redirect

          sign_out @content_editor
          sign_in @volunteer_coordinator
          assert_no_difference "Decidim::Bih::PartnerProjectSubmission.count" do
            post public_path("projekti"), params: project_submission_params
          end
          assert_response :redirect

          assert_difference "Decidim::Bih::ContributionNeed.pending_review.count", 1 do
            post public_path("volontiranje/potrebe"), params: contribution_need_params
          end
          assert_response :redirect
        end

        test "only current content members can read private submissions and resubmit requested changes" do
          submission = Decidim::Bih::PartnerProjectSubmission.create!(
            organization: @organization,
            partner_profile: @profile,
            representative: @content_editor,
            title: "Private revision",
            description: "Private review content",
            budget_amount: 2_000,
            review_status: "changes_requested",
            submitted_at: 2.days.ago,
            reviewed_at: 1.day.ago,
            rejection_reason: "Clarify the delivery plan"
          )

          sign_in @content_editor
          get public_path("projekti")
          assert_response :success
          assert_includes response.body, "Clarify the delivery plan"

          patch public_path("projekti/prijave/#{submission.id}"), params: project_submission_params(
            title: "Private revision updated"
          )
          assert_response :redirect
          assert_equal "submitted", submission.reload.review_status
          assert_equal "Private revision updated", submission.title

          submission.update!(review_status: "changes_requested", rejection_reason: "One more detail")
          membership = Decidim::Bih::PartnerMembership.find_by!(partner_profile: @profile, user: @content_editor)
          membership.update!(status: "revoked", revoked_at: Time.current)

          get public_path("projekti")
          assert_response :success
          assert_not_includes response.body, "One more detail"

          patch public_path("projekti/prijave/#{submission.id}"), params: project_submission_params(
            title: "Unauthorized update"
          )
          assert_response :redirect
          assert_equal "Private revision updated", submission.reload.title
        end

        test "community reviewer sees only its tenant and invalid campaign keys do not raise" do
          reviewer = FactoryBot.create(:user, :confirmed, organization: @organization)
          admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          Decidim::Bih::OperatorRole.create!(
            organization: @organization,
            user: reviewer,
            created_by: admin,
            role: "community_reviewer",
            expires_at: 30.days.from_now
          )
          submission = submitted_project!("Review me")
          other_organization = create_organization
          other_submission = create_other_tenant_submission!(other_organization)

          sign_in reviewer
          get "/sr/admin/bih/community-contributions"
          assert_response :success
          assert_includes response.body, submission.title
          assert_not_includes response.body, other_submission.title

          post "/sr/admin/bih/community-contributions/projects/#{submission.id}/approve",
               params: { campaign_key: "Not a valid key!" }
          assert_response :unprocessable_entity
          assert_select "input[name=campaign_key][value='Not a valid key!']", count: 1
          assert_not_includes response.body, other_submission.title
          assert_equal "submitted", submission.reload.review_status
          assert_nil submission.project
        end

        test "native budgets admin cannot trash an approved partner project" do
          project = create_visible_project!("Permanent transparency project")
          Decidim::Bih::PartnerProjectSubmission.create!(
            organization: @organization,
            partner_profile: @profile,
            representative: @content_editor,
            project:,
            title: "Permanent transparency project",
            description: "An approved project must remain a durable public record.",
            budget_amount: 5_000,
            review_status: "approved",
            submitted_at: 2.days.ago,
            reviewed_at: 1.day.ago
          )
          admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)

          sign_in admin
          %w(sr sr-Cyrl bs hr).each do |locale|
            path = native_project_soft_delete_path(project, locale:)
            assert_match %r{\A/#{Regexp.escape(locale)}/admin/}, path,
                         "the mounted admin path must carry the requested locale"
            patch path

            assert_response :redirect
            assert_nil project.reload.deleted_at
            assert_equal I18n.t(
              "decidim.bih.admin.community_contributions.project_delete_blocked",
              locale:
            ), flash[:alert]
          end
        end

        private

        def public_path(path)
          "#{Decidim::Bih.normalized_public_mount_path}/#{path}"
        end

        def native_project_path(project)
          Decidim::EngineRouter.main_proxy(project.component).budget_project_path(
            budget_id: project.budget.id,
            id: project.id,
            locale: :sr
          )
        end

        def native_project_soft_delete_path(project, locale: @organization.default_locale)
          # Upstream admin_proxy rewrites the path segment from I18n.locale,
          # even if the nested helper receives an explicit locale option.
          I18n.with_locale(locale) do
            Decidim::EngineRouter.admin_proxy(project.component).soft_delete_budget_project_path(
              budget_id: project.budget.id,
              id: project.id,
              locale:
            )
          end
        end

        def create_partner_profile!(slug, organization: @organization)
          Decidim::Bih::PartnerProfile.create!(
            organization:,
            display_name: slug.titleize,
            slug:,
            kind: "association",
            verification_status: "verified",
            verified_at: Time.current
          )
        end

        def create_membership!(user, role, profile: @profile)
          Decidim::Bih::PartnerMembership.create!(
            organization: user.organization,
            partner_profile: profile,
            user:,
            role:,
            status: "accepted",
            accepted_at: Time.current
          )
        end

        def create_visible_project!(title)
          budget = FactoryBot.create(:budget, component: FactoryBot.create(:budgets_component, organization: @organization))
          FactoryBot.create(
            :project,
            budget:,
            title: localized(title),
            description: localized("#{title} description"),
            budget_amount: 5_000
          )
        end

        def create_support_project!(title)
          process = FactoryBot.create(
            :participatory_process,
            organization: @organization,
            published_at: nil
          )
          component = FactoryBot.create(
            :budgets_component,
            participatory_space: process,
            published_at: Time.current
          )
          budget = FactoryBot.create(:budget, component:)
          Decidim::Bih::Setting.put(@organization, "community_projects", "budget_id", budget.id)
          FactoryBot.create(
            :project,
            budget:,
            title: localized(title),
            description: localized("#{title} description"),
            budget_amount: 5_000
          )
        end

        def submitted_project!(title)
          Decidim::Bih::PartnerProjectSubmission.create!(
            organization: @organization,
            partner_profile: @profile,
            representative: @content_editor,
            title:,
            description: "A bounded project submission for review.",
            budget_amount: 3_000,
            review_status: "submitted",
            submitted_at: Time.current
          )
        end

        def create_other_tenant_submission!(organization)
          user = FactoryBot.create(:user, :confirmed, organization:)
          profile = create_partner_profile!("other-tenant-partner", organization:)
          create_membership!(user, "content_editor", profile:)
          Decidim::Bih::PartnerProjectSubmission.create!(
            organization:,
            partner_profile: profile,
            representative: user,
            title: "Other tenant private project",
            description: "Must never appear in this tenant's review queue.",
            budget_amount: 4_000,
            review_status: "submitted",
            submitted_at: Time.current
          )
        end

        def project_submission_params(title: "Submitted by content editor")
          {
            partner_project_submission: {
              partner_profile_id: @profile.id,
              title:,
              description: "A project submitted through the public moderated form.",
              budget_amount: 10_000,
              address: "Community street 1"
            }
          }
        end

        def contribution_need_params
          {
            need_partner_profile_id: @profile.id,
            need_type: "equipment",
            need_title: "Ten folding tables",
            need_description: "Tables for a public neighbourhood workshop.",
            quantity: 10,
            unit: "tables"
          }
        end

        def localized(value)
          BIH_RAILS_TEST_LOCALES.index_with { value }
        end
      end
    end
  end
end
