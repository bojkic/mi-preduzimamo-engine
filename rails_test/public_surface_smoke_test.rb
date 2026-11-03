# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class PublicSurfaceSmokeTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        EXPECTED_PUBLIC_GET_SURFACE_IDS = %w(
          community_hub.show
          community_projects.index
          community_projects.show
          donations.show
          impact.index
          komsiluk_board.index
          mi_bot.show
          mz_directory.index
          mz_directory.show
          organizations.index
          organizations.show
          phone_sessions.new
          report_heatmap.index
          reports.index
          reports.new
          reports.root
          reports.show
          reports_map.show
          volunteer.index
        ).freeze

        REQUESTS = [
          ["reports.root", :html, -> { public_mount_path }],
          ["reports.new", :html, -> { "#{public_mount_path}/prijave/new" }],
          ["reports.index", :html, -> { "#{public_mount_path}/prijave" }],
          ["reports.show", :html, -> { "#{public_mount_path}/prijave/#{@report.reference}" }],
          ["reports_map.show", :html, -> { "#{public_mount_path}/mapa" }],
          ["reports_map.show", :json, -> { "#{public_mount_path}/mapa.json" }],
          ["report_heatmap.index", :html, -> { "#{public_mount_path}/mapa-problema" }],
          ["donations.show", :html, -> { "#{public_mount_path}/donacije" }],
          ["impact.index", :html, -> { "#{public_mount_path}/uticaj" }],
          ["mi_bot.show", :html, -> { "#{public_mount_path}/mi-bot" }],
          ["community_hub.show", :html, -> { "#{public_mount_path}/zajednistvo" }],
          ["community_projects.index", :html, -> { "#{public_mount_path}/projekti" }],
          ["community_projects.show", :html, -> { "#{public_mount_path}/projekti/#{@community_project.id}" }],
          ["volunteer.index", :html, -> { "#{public_mount_path}/volontiranje" }],
          ["mz_directory.index", :html, -> { "#{public_mount_path}/mjesne-zajednice" }],
          ["mz_directory.show", :html, -> { "#{public_mount_path}/mjesne-zajednice/#{@mz.slug}" }],
          ["mz_directory.show", :json, -> { "#{public_mount_path}/mjesne-zajednice/#{@mz.slug}.json" }],
          ["phone_sessions.new", :sign_in_redirect, -> { "#{public_mount_path}/prijava" }],
          ["organizations.index", :html, -> { "#{public_mount_path}/organizacije" }],
          ["organizations.show", :html, -> { "#{public_mount_path}/organizacija/#{@profile.slug}" }],
          ["komsiluk_board.index", :redirect, -> { "#{public_mount_path}/komsiluk-board" }]
        ].freeze

        setup do
          @organization = create_organization
          host! @organization.host
          @mz = create_mz_area!
          @komsiluk = create_komsiluk_area!
          @report = create_report!
          @group = create_group!
          @profile = create_partner_profile!
          @community_project = create_community_project!
        end

        test "manifest public get surfaces render in a custom generated host" do
          assert_equal expected_public_mount_path, public_mount_path
          assert_equal EXPECTED_PUBLIC_GET_SURFACE_IDS, manifest_public_get_ids
          assert_request_matrix_covers_manifest_public_get_paths

          REQUESTS.each do |surface_id, expected, path_builder|
            path = instance_exec(&path_builder)
            assert_manifest_declares_path(surface_id, path)

            get path

            case expected
            when :html
              assert_successful_html(path)
              assert_no_default_mount_link_leaks(path)
              assert_no_host_brand_text_leaks(path)
            when :sign_in_redirect
              assert_redirected_to "/sr/users/sign_in"
              follow_redirect!
              assert_successful_html("/sr/users/sign_in")
              assert_no_default_mount_link_leaks("/sr/users/sign_in")
            when :json
              assert_successful_json(path)
              assert_not_includes response.body, default_mount_path
            when :redirect
              assert_public_redirect(path)
            end
          end
        end

        private

        def public_mount_path
          Decidim::Bih.normalized_public_mount_path
        end

        def expected_public_mount_path
          Decidim::Bih.normalize_public_mount_path(ENV.fetch("MOUNT_PATH", "/moja-platforma"))
        end

        def default_mount_path
          "/biceriseno"
        end

        def manifest
          @manifest ||= Decidim::Bih.required_public_surface_manifest(mount_path: public_mount_path)
        end

        def manifest_public_get_ids
          manifest_public_get_surfaces.map { |surface| surface.fetch(:id) }.sort
        end

        def assert_request_matrix_covers_manifest_public_get_paths
          expected_paths_by_id = manifest_public_get_surfaces.to_h do |surface|
            [surface.fetch(:id), manifest_paths_for(surface).sort]
          end
          actual_paths_by_id = request_paths_by_surface_id.transform_values(&:sort)

          assert_equal expected_paths_by_id, actual_paths_by_id
        end

        def assert_manifest_declares_path(surface_id, path)
          surface = manifest.find { |row| row.fetch(:id) == surface_id }
          assert surface, "Expected public-surface manifest to include #{surface_id}"

          normalized_paths = manifest_paths_for(surface)
          assert_includes normalized_paths, path
          assert normalized_paths.all? { |manifest_path| manifest_path.start_with?(public_mount_path) },
                 "Expected #{surface_id} paths to use #{public_mount_path}: #{normalized_paths.inspect}"
        end

        def manifest_public_get_surfaces
          manifest.select do |surface|
            surface.fetch(:visibility) == "public" && surface.fetch(:methods).include?("GET")
          end
        end

        def manifest_paths_for(surface)
          surface.fetch(:paths).map { |manifest_path| sample_manifest_path(manifest_path) }
        end

        def request_paths_by_surface_id
          REQUESTS.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(surface_id, _expected, path_builder), paths|
            paths[surface_id] << instance_exec(&path_builder)
          end
        end

        def sample_manifest_path(path)
          path
            .sub(":reference", @report.reference)
            .sub(":slug", @mz.slug)
            .sub("projekti/:id", "projekti/#{@community_project.id}")
            .sub(":id", @profile.slug)
        end

        def assert_successful_html(path)
          assert_response :success, failure_message(path)
          assert_equal "text/html", response.media_type
          assert response.body.present?, "Expected #{path} to render a non-empty HTML response"
        end

        def assert_successful_json(path)
          assert_response :success, failure_message(path)
          assert_equal "application/json", response.media_type
          assert response.body.present?, "Expected #{path} to render a non-empty JSON response"
        end

        def assert_public_redirect(path)
          assert_response :redirect, failure_message(path)
          assert_operator response.status, :<, 400
          assert_match %r{/users/sign_in}, response.location
        end

        def assert_no_default_mount_link_leaks(path)
          leaks = response.body.scan(%r{\b(?:href|action|src|data-[\w-]+)=["'][^"']*/biceriseno[^"']*}i)
          assert_empty leaks, "Expected #{path} not to render #{default_mount_path} links/actions/data attributes"
        end

        def assert_no_host_brand_text_leaks(path)
          forbidden = [
            %r{/biceriseno}i,
            /\blfbn\b/i,
            /fondacijabijeljina/i,
            /MI!/i,
            /Biće riješeno/i,
            /Биће ријешено/i
          ]

          forbidden.each do |pattern|
            assert_no_match pattern, response.body, "Expected #{path} not to render host-specific token #{pattern.inspect}"
          end
        end

        def failure_message(path)
          "Expected #{path} to be reachable; got #{response.status}\n#{response.body.to_s.first(500)}"
        end

        def create_report!
          Decidim::Bih::Report.create!(
            organization: @organization,
            description: "Broken pavement near the generated host smoke route.",
            category: "putevi",
            severity: "normalan",
            status: "primljeno",
            address: "Rails smoke street",
            latitude: 44.758,
            longitude: 19.214,
            mz_slug: @mz.slug
          )
        end

        def create_mz_area!
          Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "mz",
            slug: "centar",
            name: localized("Centar"),
            boundary: square_boundary,
            centroid_lat: 44.758,
            centroid_lon: 19.214,
            predsjednik: "Rails Smoke",
            telefon: "+38755111000"
          )
        end

        def create_komsiluk_area!
          Decidim::Bih::LocalArea.create!(
            organization: @organization,
            kind: "komsiluk",
            slug: "centar-istok",
            name: localized("Centar istok"),
            boundary: square_boundary,
            centroid_lat: 44.758,
            centroid_lon: 19.214,
            primary_mz_slug: @mz.slug,
            overlapping_mz_slugs: [@mz.slug]
          )
        end

        def create_group!
          FactoryBot.create(
            :user,
            :confirmed,
            organization: @organization,
            name: "Rails smoke group",
            nickname: "rsg-#{SecureRandom.hex(6)}",
            email: "rails-smoke-group-#{SecureRandom.hex(6)}@example.test",
            extended_data: { group: true }
          )
        end

        def create_partner_profile!
          Decidim::Bih::PartnerProfile.create!(
            organization: @organization,
            legacy_user_group: @group,
            display_name: "Rails smoke group",
            slug: "rails-smoke-group",
            kind: "association",
            verification_status: "verified",
            verified_at: Time.current
          )
        end

        def create_community_project!
          representative = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::PartnerMembership.create!(
            organization: @organization,
            partner_profile: @profile,
            user: representative,
            role: "content_editor",
            status: "accepted",
            accepted_at: Time.current
          )
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
          project = FactoryBot.create(
            :project,
            budget:,
            title: localized("Generated host community project"),
            description: localized("Approved public project used by the generated-host smoke."),
            budget_amount: 5_000
          )
          Decidim::Bih::PartnerProjectSubmission.create!(
            organization: @organization,
            partner_profile: @profile,
            representative:,
            reviewer: representative,
            project:,
            title: "Generated host community project",
            description: "Approved public project used by the generated-host smoke.",
            budget_amount: 5_000,
            review_status: "approved",
            submitted_at: 1.day.ago,
            reviewed_at: Time.current
          )
          Decidim::Bih::ProjectDonationLink.create!(
            organization: @organization,
            project:,
            campaign_key: "generated-host-community-project"
          )
          project
        end

        def localized(value)
          BIH_RAILS_TEST_LOCALES.index_with { value }
        end

        def square_boundary
          {
            "type" => "Polygon",
            "coordinates" => [
              [
                [19.20, 44.75],
                [19.23, 44.75],
                [19.23, 44.77],
                [19.20, 44.77],
                [19.20, 44.75]
              ]
            ]
          }
        end
      end
    end
  end
end
