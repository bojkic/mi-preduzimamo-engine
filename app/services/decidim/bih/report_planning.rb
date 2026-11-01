# frozen_string_literal: true

module Decidim
  module Bih
    class ReportPlanning
      class Invalid < StandardError; end

      # Owner decision 2026-10-05: collections go to the City together at the
      # end of the year. Late in December the date rolls to the next year end.
      def self.default_review_due_at(now = Time.current)
        year_end = now.end_of_year.change(hour: 12)
        year_end < now + 14.days ? (now + 1.year).end_of_year.change(hour: 12) : year_end
      end

      def initialize(report, actor)
        @report = report
        @actor = actor
      end

      def location(attributes)
        authorize!
        values = attributes.to_h.symbolize_keys
        expected_collection = @report.report_collection_id
        (@report.report_collection || @report).with_lock do
          @report.with_lock do
            fail_with(:collection_locked) unless @report.report_collection_id == expected_collection
            fail_with(:sent_locked) if @report.forwarded_at.present? || @report.report_collection&.submitted_at.present?
            attrs = location_attributes(values)
            original = @report.original_location.presence || @report.attributes.slice("address", "latitude", "longitude", "mz_slug", "public_location_exact")
            @report.update!(attrs.merge(original_location: original, location_reviewed_at: Time.current, location_reviewed_by: @actor,
                                        mz_slug: location_mz(attrs), public_location_exact: false))
            @report.report_collection&.update!(state: "collecting")
            @report.record_event!("case_location_updated", actor: @actor, metadata: { location_kind: attrs[:location_kind], has_coordinates: attrs[:latitude].present? })
          end
        end
      end

      def plan(attributes)
        authorize!
        values = attributes.to_h.symbolize_keys
        collection = ReportCollection.find_by(id: values[:report_collection_id], organization: @report.organization)
        fail_with(:collection_required) unless collection
        collection.with_lock do
          @report.with_lock do
            validate_plan!(collection, values)
            @report.update!(report_collection: collection, report_subtype: values[:report_subtype].to_s.strip,
                            forwarding_note: values[:forwarding_note].to_s.strip, status: "planirano", review_state: "validated",
                            reviewed_by: @actor, reviewed_at: Time.current, assigned_to: collection.assigned_to, response_due_at: collection.review_due_at)
            collection.update!(state: "collecting")
            @report.record_event!("case_planning_updated", actor: @actor, metadata: { collection_id: collection.id, status: "planirano" })
          end
        end
      end

      def unplan
        authorize!
        collection = @report.report_collection
        fail_with(:collection_required) unless collection
        collection.with_lock do
          @report.with_lock do
            fail_with(:sent_locked) unless collection.draft? && @report.forwarded_at.nil?
            settled = Report::TERMINAL_STATUSES.include?(@report.status)
            @report.update!(report_collection: nil, status: settled ? @report.status : "u_obradi", review_state: settled ? @report.review_state : "pending")
            collection.update!(state: "collecting")
            @report.record_event!("case_planning_updated", actor: @actor, metadata: { previous_collection_id: collection.id, status: @report.status })
          end
        end
      end

      private

      def location_attributes(values)
        kind = values[:location_kind].to_s
        fail_with(:location_invalid) unless %w(description point segment).include?(kind)
        address = values[:address].to_s.strip
        fail_with(:location_invalid) if address.blank? || address.length > 500
        lat, lng = pair(values[:latitude], values[:longitude])
        end_lat, end_lng = pair(values[:location_end_latitude], values[:location_end_longitude])
        validate_shape!(kind, lat, end_lat)
        { address: address, latitude: lat, longitude: lng, location_end_latitude: end_lat, location_end_longitude: end_lng, location_kind: kind }
      end

      def validate_shape!(kind, lat, end_lat)
        fail_with(:location_invalid) if kind == "point" && lat.nil?
        fail_with(:location_invalid) if kind != "segment" && end_lat
        fail_with(:location_invalid) if kind == "segment" && lat.nil? != end_lat.nil?
      end

      def location_mz(values)
        return if values[:latitude].nil?

        first = Geo::PointRouting.resolve(lat: values[:latitude], lon: values[:longitude], organization: @report.organization)[:mz_slug]
        return first unless values[:location_end_latitude]

        last = Geo::PointRouting.resolve(lat: values[:location_end_latitude], lon: values[:location_end_longitude], organization: @report.organization)[:mz_slug]
        first if first == last
      rescue StandardError
        nil
      end

      # rubocop:disable Metrics/CyclomaticComplexity -- independent staff planning prerequisites
      def validate_plan!(collection, values)
        fail_with(:sent_locked) unless collection.draft? && @report.forwarded_at.nil? && Report::TERMINAL_STATUSES.exclude?(@report.status)
        fail_with(:collection_locked) if @report.collective? && @report.report_collection_id != collection.id
        fail_with(:confirm_required) unless values[:confirm_review] == "1"
        fail_with(:location_invalid) if @report.address.blank? && values[:report_subtype] != "opsti_prijedlog"
        fail_with(:summary_required) if values[:forwarding_note].to_s.strip.blank?
        validate_owner_due!(collection)
      end

      # rubocop:enable Metrics/CyclomaticComplexity

      def validate_owner_due!(collection)
        unless ReportCaseWorkflow.staff(collection.organization).exists?(id: collection.assigned_to_id) && collection.review_due_at && collection.review_due_at > Time.current
          fail_with(:owner_due_required)
        end
      end

      def authorize!
        raise Decidim::ActionForbidden unless OperatorAuthorization.allowed?(@actor, :reports_update_status, organization: @report.organization)
      end

      def pair(latitude, longitude)
        return [nil, nil] if latitude.blank? && longitude.blank?

        lat = Float(latitude)
        lng = Float(longitude)
        fail_with(:location_invalid) unless lat.finite? && lng.finite? && (-90..90).cover?(lat) && (-180..180).cover?(lng)
        [lat, lng]
      rescue ArgumentError, TypeError
        fail_with(:location_invalid)
      end

      def fail_with(key)
        raise Invalid, I18n.t("decidim.bih.report_planning.errors.#{key}")
      end
    end
  end
end
