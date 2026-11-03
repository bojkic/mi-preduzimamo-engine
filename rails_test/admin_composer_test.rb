# frozen_string_literal: true

require_relative "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Render the current board publication preview and the private operator
      # message composer. Signed confirmation binds actor, source and audience;
      # the retired broadcast endpoint must not create a second send path.
      class AdminComposerTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mira Mjesto")
          @area = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id, kind: "komsiluk",
            slug: "k-composer-#{SecureRandom.hex(4)}", name: { "sr" => "Komšiluk Proba" }
          )
        end

        def publication_attributes
          { title: "Akcija komšiluka", body: "Sutra čišćenje trga.", category: "general",
            expires_at: 1.day.from_now.iso8601, area_ids: [@area.id] }
        end

        def preview!
          post "/sr/admin/bih/board-notices/preview", params: { notice: publication_attributes }
          assert_response :success
          css_select("input[name=confirmation_token]").first["value"]
        end

        test "the retired broadcast endpoint redirects without sending" do
          sign_in @admin
          assert_no_difference [-> { Broadcast.count }, -> { KomsilukPost.count }, -> { KomsilukPhoneDelivery.count }] do
            post "/admin/bih/broadcasts", params: { local_area_id: @area.id, message: "Old request", confirm_preview: "1" }
          end
          assert_redirected_to "/admin/bih/board-notices/new?locale=sr"
        end

        test "the publication preview exposes aggregate audience without recipients or delivery" do
          CitizenProfile.for_user(@citizen, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
          sign_in @admin
          assert_no_difference [-> { KomsilukPost.count }, -> { KomsilukPhoneDelivery.count }] do
            preview!
          end
          assert_select "#board-notice-preview", 1
          intent = KomsilukSendIntent.find_by!(organization: @organization, actor: @admin)
          assert_equal 1, intent.recipients_count
          assert_not_includes response.body, @citizen.email
          assert_not_includes response.body, @citizen.name
          assert_includes response.body, publication_attributes[:body]
        end

        test "phone channels are explicit and unselected by default" do
          sign_in @admin
          get "/sr/admin/bih/board-notices/new"
          assert_response :success
          assert_select "input[name='notice[channels][]']", 3
          assert_select "input[name='notice[channels][]'][checked]", 0
        end

        test "signed confirmation publishes once and cannot replace the reviewed text" do
          sign_in @admin
          token = preview!
          assert_no_difference -> { KomsilukPhoneDelivery.count } do
            assert_difference -> { KomsilukPost.where(organization: @organization).count }, 1 do
              2.times do
                post "/sr/admin/bih/board-notices/confirm", params: { confirmation_token: token, notice: { body: "Unreviewed text" } }
              end
            end
          end
          published = KomsilukPost.find_by!(organization: @organization)
          assert_equal publication_attributes[:body], published.body
          assert_redirected_to "/sr/admin/bih/komsiluk-posts/#{published.id}"
        end

        test "an expired preview cannot publish or send" do
          sign_in @admin
          token = preview!
          travel Komsiluk::NoticeComposer::PREVIEW_TTL + 1.minute do
            assert_no_difference [-> { KomsilukPost.count }, -> { KomsilukPhoneDelivery.count }] do
              post "/sr/admin/bih/board-notices/confirm", params: { confirmation_token: token }
            end
          end
          assert_not KomsilukSendIntent.find_by!(organization: @organization).state == "confirmed"
        end

        test "a changed audience is refused at confirmation" do
          sign_in @admin
          token = preview!
          CitizenProfile.for_user(@citizen, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
          assert_no_difference -> { KomsilukPost.count } do
            post "/sr/admin/bih/board-notices/confirm", params: { confirmation_token: token }
          end
          assert_response :unprocessable_entity
        end

        test "swapping a recipient while retaining the count also invalidates preview" do
          first_profile = CitizenProfile.for_user(@citizen, organization: @organization)
          first_profile.assign_komsiluk!(@area, source: "dropdown")
          replacement = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in @admin
          token = preview!
          first_profile.update!(komsiluk: nil)
          CitizenProfile.for_user(replacement, organization: @organization).assign_komsiluk!(@area, source: "dropdown")
          assert_no_difference -> { KomsilukPost.count } do
            post "/sr/admin/bih/board-notices/confirm", params: { confirmation_token: token }
          end
          assert_response :unprocessable_entity
        end

        test "another administrator cannot reuse the signed confirmation" do
          sign_in @admin
          token = preview!
          sign_in FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          assert_no_difference -> { KomsilukPost.count } do
            post "/sr/admin/bih/board-notices/confirm", params: { confirmation_token: token }
          end
          assert_response :redirect
        end

        # ---- the operator message surface --------------------------------

        def report_for(author, status: "u_obradi")
          Decidim::Bih::Report.create!(organization: @organization, author:, description: "Rupa na putu.",
                                       category: "putevi", severity: "normalan", status:,
                                       address: "Harness 1", latitude: 44.758, longitude: 19.214)
        end

        test "the operator composer renders inside an authorized case and names the recipient" do
          report = report_for(@citizen)
          sign_in @admin
          post "/sr/admin/bih/messages", params: {
            context_type: "report", context_id: report.id, subject: "Status", body: "Radimo na tome.",
            external_copy: "1", delivery_preview: "1"
          }

          assert_response :success
          assert_select "[data-composer-audience]"
          assert_select "[data-composer-recipient]", 1
        end

        test "an operator message with an expired delivery token is refused, and nothing is sent" do
          report = report_for(@citizen)
          sign_in @admin
          post "/sr/admin/bih/messages", params: {
            context_type: "report", context_id: report.id, subject: "Status", body: "Radimo na tome.",
            external_copy: "1", delivery_preview: "1"
          }
          token = css_select("input[name=delivery_token]").first["value"]
          assert token.present?

          travel 11.minutes do
            assert_no_difference -> { Decidim::Bih::OperatorMessage.count } do
              post "/sr/admin/bih/messages", params: {
                context_type: "report", context_id: report.id, subject: "Status", body: "Radimo na tome.",
                external_copy: "1", message_reviewed: "1", delivery_token: token
              }
            end
          end
          assert_response :unprocessable_entity
        end

        # ---- Task 5.3: side effects state their consequences --------------

        test "a report page tells the operator which messages a status change triggers" do
          report = report_for(@citizen)
          sign_in @admin
          get "/sr/admin/bih/reports/#{report.reference}"

          assert_response :success
          assert_select "[data-send-consequence='report.reporter_status_email']", 1
          assert_select "[data-send-consequence='report.author_external_copy']", 1
        end

        test "legacy status mutation returns to the unified decision without sending" do
          report = report_for(@citizen, status: "primljeno")
          sign_in @admin
          # Devise tracks this first authenticated request by updating the
          # user's descendants; no report, mail or notification job may enqueue.
          assert_no_enqueued_jobs except: Decidim::FindAndUpdateDescendantsJob do
            patch "/sr/admin/bih/reports/#{report.reference}/status", params: { status: "u_obradi" }
          end

          assert_response :redirect
          assert_equal "primljeno", report.reload.status
          assert_empty report.case_messages
          assert_empty report.dispatches
        end

        test "the report page renders no composer, because a case is not a bulk send" do
          report = report_for(@citizen)
          sign_in @admin
          get "/sr/admin/bih/reports/#{report.reference}"

          assert_select "[data-composer]", 0
          assert_select "[data-composer-confirm]", 0
        end

        test "awarding points states that a message follows and by which channels" do
          sign_in @admin
          get "/sr/admin/bih/citizens/#{@citizen.id}"

          assert_response :success
          assert_select "[data-send-consequence='goodwill.points_earned']", 1
          assert_includes response.body, I18n.t("decidim.bih.admin.composer.channels.bell", locale: :sr)
        end

        # The strip is registry-derived, so a page that triggers nothing shows
        # nothing rather than a reassuring empty box.
        test "a surface that sends nothing renders no consequences strip" do
          sign_in @admin
          get "/sr/admin/bih/rewards"

          assert_response :success
          assert_select "[data-send-consequences]", 0
        end

        test "an operator message without an external copy still sends in one submit" do
          report = report_for(@citizen)
          sign_in @admin
          assert_difference -> { Decidim::Bih::OperatorMessage.count }, 1 do
            post "/sr/admin/bih/messages", params: {
              context_type: "report", context_id: report.id, subject: "Status", body: "Radimo na tome.",
              message_reviewed: "1"
            }
          end
        end
      end
    end
  end
end
