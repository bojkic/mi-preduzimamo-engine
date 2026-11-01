# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Round 25 (W4.3) — admin editor for the 70 Mjesne zajednice (and
      # komšiluci): list with a kind filter, plus an edit form for the contact
      # fields (predsjednik, telefon) and metadata-safe fields. The BOUNDARY is
      # deliberately NOT editable here — geometry stays rake-imported
      # (decidim_bih:geo:import_areas) so an admin can never corrupt it by hand.
      #
      # Permission model: global-admin gated; all reads/writes scoped to
      # current_organization, so an admin can never see or edit another org's
      # areas (the scoped find returns nil → redirect, never 500).
      class LocalAreasController < Decidim::Bih::Admin::ApplicationController
        include Decidim::Bih::Admin::ScopedFinder

        KINDS = Decidim::Bih::LocalArea::KINDS
        WORKFLOW_TABS = %w(mz komsiluk routing).freeze
        DEFAULT_WORKFLOW_TAB = "mz"

        before_action -> { require_bih_permission!(:local_area_manage) }

        # GET /admin/bih/local-areas
        def index
          @active_local_areas_tab = active_workflow_tab
          @local_area_counts = scoped_local_areas.group(:kind).count
          @mz_by_slug = scoped_local_areas.mz.index_by(&:slug)
          @local_areas = local_areas_for_active_tab
          @komsiluk_routing_rows = komsiluk_routing_rows if @active_local_areas_tab == "routing"
        end

        # GET /admin/bih/local-areas/:id/edit
        # The finder redirects on a miss; the guard then halts so we never fall
        # through and render the edit template on top of that redirect.
        # rubocop:disable Style/RedundantReturn -- the `return` is load-bearing:
        # it halts the action on a not-found so the finder's redirect is the only
        # response; dropping it reintroduces the fall-through render bug.
        def edit
          return unless (@local_area = find_local_area!)
        end
        # rubocop:enable Style/RedundantReturn

        # PATCH/PUT /admin/bih/local-areas/:id
        def update
          @local_area = find_local_area!
          return unless @local_area

          attributes = local_area_attributes
          changed_fields = changed_local_area_fields(attributes)
          if changed_fields.any? && approval_rationale.blank?
            @local_area.assign_attributes(attributes)
            flash.now[:alert] = t(".approval_rationale_required")
            render :edit, status: :unprocessable_entity
            return
          end

          if @local_area.update(attributes)
            audit_operator_action!(
              "local_area_updated",
              permission: "local_area_manage",
              resource: @local_area,
              metadata: {
                kind: @local_area.kind,
                slug: @local_area.slug,
                changed_fields:,
                approval_rationale: approval_rationale.presence
              }
            )
            flash[:notice] = t(".updated")
            redirect_to local_areas_path(tab: @local_area.kind)
          else
            flash.now[:alert] = t(".update_failed")
            render :edit, status: :unprocessable_entity
          end
        end

        private

        def scoped_local_areas
          Decidim::Bih::LocalArea.where(decidim_organization_id: current_organization.id)
        end

        def active_workflow_tab
          requested = params[:tab].to_s
          return requested if WORKFLOW_TABS.include?(requested)

          legacy_kind = params[:kind].to_s
          return legacy_kind if KINDS.include?(legacy_kind)

          DEFAULT_WORKFLOW_TAB
        end

        def local_areas_for_active_tab
          scope = scoped_local_areas
          scope = scope.where(kind: @active_local_areas_tab) if KINDS.include?(@active_local_areas_tab)
          scope.order(:kind, :slug)
        end

        def komsiluk_routing_rows
          scoped_local_areas.komsiluci.order(:slug).map do |area|
            overlapping_slugs = Array(area.overlapping_mz_slugs).compact_blank
            {
              area:,
              primary_mz: @mz_by_slug[area.primary_mz_slug],
              overlapping_mz: overlapping_slugs.filter_map { |slug| @mz_by_slug[slug] },
              overlapping_slugs:
            }
          end
        end

        def find_local_area!
          find_scoped!(
            scoped_local_areas,
            id: params[:id],
            redirect_to: local_areas_path,
            flash_key: "decidim.bih.admin.local_areas.not_found"
          )
        end

        # Only the contact fields are writable. Boundary/centroid/slug/kind stay
        # rake-owned. metadata accepts the operator-safe descriptive keys merged
        # over (not replacing) the existing GIS-export metadata.
        def local_area_attributes
          {
            predsjednik: params.dig(:local_area, :predsjednik).to_s.strip.presence,
            telefon: params.dig(:local_area, :telefon).to_s.strip.presence,
            metadata: merged_metadata
          }
        end

        # Merges the operator-editable note over the existing metadata so the
        # rake-imported GIS fields (povrsina_m2, naziv_gis, …) are preserved.
        def merged_metadata
          existing = @local_area.metadata.is_a?(Hash) ? @local_area.metadata : {}
          note = params.dig(:local_area, :napomena).to_s.strip
          merged = existing.merge("napomena" => note)
          # Only drop the operator-owned note when blank; never blanket-compact,
          # which would silently strip rake-imported GIS keys that are legitimately
          # nil (e.g. {"izvor" => nil}).
          merged.delete("napomena") if note.blank?
          merged
        end

        def changed_local_area_fields(attributes)
          fields = []
          fields << "predsjednik" if @local_area.predsjednik != attributes[:predsjednik]
          fields << "telefon" if @local_area.telefon != attributes[:telefon]
          fields << "napomena" if @local_area.metadata != attributes[:metadata]
          fields
        end

        def approval_rationale
          params[:approval_rationale].to_s.strip
        end
      end
    end
  end
end
