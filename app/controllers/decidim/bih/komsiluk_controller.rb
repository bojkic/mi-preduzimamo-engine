# frozen_string_literal: true

module Decidim
  module Bih
    # The Komšiluk picker — lets a signed-in citizen assign themselves to a
    # neighbourhood (Komšiluk) privately, with MZ resolved independently.
    #
    # Three methods are offered, all funnelling into the same #update action:
    #   1. Map-click: Leaflet map + GeoJSON polygon layer; citizen clicks a polygon.
    #      A point (lat/lon) is also sent → MZ resolved by point-in-polygon.
    #   2. Address suggest: text field → server-side Nominatim geocode → AreaLocator →
    #      suggested komšiluk displayed for confirmation. ADDRESS IS DISCARDED.
    #      MZ is resolved by point-in-polygon on the geocoded coords.
    #   3. Dropdowns: komšiluk select (no geocoding, no point) → MZ falls back to
    #      komsiluk.primary_mz (the computed soft pointer). Source stored as "dropdown".
    #
    # PRIVACY CONTRACT:
    #   - The citizen's typed address is NEVER stored, logged, or forwarded.
    #   - A point (lat/lon) sent with map-click or suggest is used TRANSIENTLY
    #     to resolve mz_id and is then DISCARDED — never stored on any record.
    #   - Only komsiluk_id + mz_id + source are persisted on CitizenProfile.
    #   - Public profiles may show only the translated komšiluk name when the
    #     user allows public recognition; address, MZ, source and coordinates
    #     are never public.
    #
    # MZ is resolved INDEPENDENTLY of komšiluk (decoupled model):
    #   - With a point → AreaLocator.resolve() → mz from MZ polygon set.
    #   - Without a point (dropdown) → komsiluk.primary_mz (soft slug pointer).
    #
    # Routes:
    #   GET  /biceriseno/komsiluk            → #edit  (picker page)
    #   PATCH /biceriseno/komsiluk           → #update (save assignment)
    #   GET  /biceriseno/komsiluk/areas.json → #areas (polygon endpoint)
    #   POST /biceriseno/komsiluk/suggest    → #suggest (address geocode)
    class KomsilukController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser

      # Two endpoints are public. The areas GeoJSON contains only polygon
      # geometry, area names and ids — no citizen data. Suggest is stateless:
      # it geocodes the typed address in-request, never stores or logs it,
      # touches no user, and answers with nothing but a komšiluk id and name —
      # the one-step registration form (which has no session to gate on) uses
      # it to pre-fill its komšiluk select. The host throttles it per IP and
      # per session (bih/komsiluk.suggest/* in the host's
      # config/initializers/rack_attack.rb). Auth is required for the picker
      # and update, which write personal data.
      before_action :require_login!, except: [:areas, :suggest]

      def edit
        Komsiluk::ReturnPath.store(session, organization: current_organization, path: params[:return_to]) if params[:return_to].present?
        user = current_organization_user
        @profile = Decidim::Bih::CitizenProfile.find_by(
          decidim_organization_id: current_organization.id,
          decidim_user_id: user.id
        )
        @komsiluk_list = flat_komsiluk_list
        @map_center = Decidim::Bih.map_default_center
        @map_zoom = Decidim::Bih.map_default_zoom
      end

      # PATCH /biceriseno/komsiluk
      # Params:
      #   komsiluk_id  Integer  required
      #   source       String   required ("map"|"address"|"dropdown"|"postal")
      #   lat          Float    optional — point for independent MZ resolution
      #   lon          Float    optional — point for independent MZ resolution
      #
      # When lat+lon are supplied the MZ is resolved by point-in-polygon (map/address).
      # When only komsiluk_id+source=dropdown are given, MZ falls back to primary_mz.
      def update
        komsiluk_id = params[:komsiluk_id].presence
        source = params[:source].presence

        unless komsiluk_id && CitizenProfile::SOURCES.include?(source.to_s)
          flash[:alert] = t(".invalid_params")
          return redirect_to(edit_komsiluk_path)
        end

        komsiluk = Decidim::Bih::LocalArea.find_by(
          id: komsiluk_id,
          decidim_organization_id: current_organization.id,
          kind: "komsiluk"
        )

        unless komsiluk
          flash[:alert] = t(".komsiluk_not_found")
          return redirect_to(edit_komsiluk_path)
        end

        # Resolve MZ independently by point when lat/lon are supplied.
        # The coordinates are used transiently and never stored.
        resolved_mz = resolve_mz_from_point
        user = current_organization_user

        first_assignment = false
        user.with_lock do
          profile = Decidim::Bih::CitizenProfile.for_user(user, organization: current_organization)
          first_assignment = !profile.assigned?
          profile.assign_komsiluk!(komsiluk, source:, resolved_mz:)
          save_registration_preferences!(user) if first_assignment
        end

        # Award points on the FIRST assignment only (idempotency key prevents
        # double-award), and only once the phone is verified (Sybil gate, spec
        # 9.1). An unverified citizen still gets the komšiluk saved — the choice
        # is never blocked — but the points wait for the first granted `sms`,
        # which pays them from authorization_referral_override.rb — for a komšiluk
        # the citizen CHOSE. Deliberately `sms` only: a postal_letter grant
        # assigns the komšiluk from the verified address rather than from a
        # choice, and that hook skips source == "postal" for the same reason.
        sms_granted = Decidim::Authorization.where(user:, name: "sms").where.not(granted_at: nil).exists?
        Decidim::Bih::Goodwill::AwardDispatch.komsiluk_selected(user) if first_assignment && sms_granted

        flash[:notice] = t(".success", name: komsiluk.translated_name)
        redirect_to(assignment_destination(user, first_assignment:))
      end

      # GET /biceriseno/komsiluk/areas.json
      # Serves tenant-scoped GeoJSON of komšiluk polygons + names + ids.
      # NO citizen data is included (only area geometry, name, id).
      def areas
        areas = Decidim::Bih::LocalArea
                .komsiluci
                .where(decidim_organization_id: current_organization.id)
                .where.not(boundary: nil)

        features = areas.map do |area|
          {
            type: "Feature",
            geometry: area.boundary,
            properties: {
              id: area.id,
              slug: area.slug,
              name: area.translated_name,
              primary_mz_slug: area.primary_mz_slug
            }
          }
        end

        render json: { type: "FeatureCollection", features: }
      end

      # POST /biceriseno/komsiluk/suggest
      # Geocodes the typed address, runs PIP, returns the suggested komšiluk.
      # The address string is NEVER stored or logged.
      # The geocoded coordinates are used transiently for PIP only.
      # Public (no login): it must never read current_user — it is scoped by
      # current_organization alone, so an anonymous visitor on the
      # registration form gets exactly what a signed-in citizen gets.
      def suggest
        # The address param is used only transiently within this request.
        # It is deliberately not assigned to any instance variable to prevent
        # accidental logging by template renderers.
        address = params[:address].to_s.strip
        return render json: Decidim::Bih::Geo::AddressSuggestions.new(organization: current_organization).call(address) if params[:purpose] == "membership"

        result = nil

        if address.present?
          coords = Decidim::Bih::Geo::Geocoder.coordinates(address)
          if coords
            locator = Decidim::Bih::Geo::AreaLocator.new
            resolved = locator.resolve(
              lat: coords[:lat],
              lon: coords[:lon],
              organization: current_organization
            )
            result = {
              komsiluk: resolved[:komsiluk],
              mz: resolved[:mz],
              lat: coords[:lat],
              lon: coords[:lon]
            }
          end
        end

        if result && result[:komsiluk].nil?
          # Geocoded, but outside every komšiluk polygon. The report intake only
          # needs the point; the registration form reads `found` and ignores it.
          render json: { found: false, message: t(".no_match"), lat: result[:lat], lon: result[:lon] }
        elsif result
          render json: {
            found: true,
            komsiluk_id: result[:komsiluk].id,
            komsiluk_name: result[:komsiluk].translated_name,
            mz_name: result[:mz]&.translated_name,
            lat: result[:lat],
            lon: result[:lon]
          }
        else
          render json: { found: false, message: t(".no_match") }
        end
      end

      private

      def save_registration_preferences!(user)
        return unless Decidim::Bih.simplified_registration && user.phone_only_registration?
        return if user.extended_data.to_h["mi_registration_preferences_selected"] == true

        enabled = params[:komsiluk_notifications].to_s == "1"
        TopicPreferences.set_all!(user, enabled:, source: "account")
        user.update!(extended_data: user.extended_data.to_h.merge("mi_registration_preferences_selected" => true),
                     newsletter_notifications_at: enabled ? Time.current : nil)
      end

      def assignment_destination(user, first_assignment:)
        destination = Onboarding::ReturnPath.consume(session, user:, organization: current_organization) ||
                      Komsiluk::ReturnPath.consume(session, organization: current_organization)
        if first_assignment && Decidim::Bih.simplified_registration && user.phone_only_registration?
          destination ||= Onboarding::NextStep.for(user, organization: current_organization)
        end
        destination || edit_komsiluk_path
      end

      def require_login!
        return if current_organization_user

        # Standardised citizen sign-in gate: set the same kind of contextual flash
        # the Komšiluk board uses and send the visitor to the sign-in form (not the
        # bare homepage), so the redirect explains itself AND lands somewhere useful.
        flash[:alert] = t("decidim.bih.komsiluk.edit.login_required")
        redirect_to(decidim.new_user_session_path)
      end

      def flat_komsiluk_list
        Decidim::Bih::LocalArea
          .komsiluci
          .where(decidim_organization_id: current_organization.id)
          .order(Arel.sql("name->>'sr'"))
      end

      # Resolve MZ by point if lat/lon params are present.
      # Returns a LocalArea (MZ kind) or nil.
      # The coordinates are used transiently and immediately discarded.
      def resolve_mz_from_point
        lat = params[:lat].presence&.to_f
        lon = params[:lon].presence&.to_f
        return nil unless lat && lon

        Decidim::Bih::Geo::AreaLocator.new.locate_mz(
          lat:,
          lon:,
          organization: current_organization
        )
      end
    end
  end
end
