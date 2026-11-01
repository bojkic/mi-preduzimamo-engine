# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Three independent, paginated operator queues. Every count is computed
      # from the same organization-scoped relation used for its displayed rows.
      class VolunteeringRoster
        PER_PAGE = 20
        TABS = %w(opportunities applications hours).freeze
        STATUSES = %w(all pending needs_revision approved active inactive rejected cancelled).freeze
        APPLICATION_TASKS = %w(all review attendance).freeze
        APPLICATION_STATUSES = %w(all pending approved automatic rejected closed).freeze
        HOUR_STATUSES = %w(all pending approved rejected).freeze
        GROUP_KEY = "COALESCE(NULLIF(decidim_bih_volunteer_opportunities.proposal_identity, ''), NULLIF(decidim_bih_volunteer_opportunities.series_key, ''), 'single:' || decidim_bih_volunteer_opportunities.id::text)"

        attr_reader :organization

        def initialize(organization, filters: {})
          @organization = organization
          @raw_filters = filters.to_h.symbolize_keys
        end

        def filters
          @filters ||= {
            tab: allowed(:tab, TABS, "opportunities"),
            status: allowed(:status, status_values, "all"),
            task: allowed(:task, APPLICATION_TASKS, "all"),
            q: raw_filters[:q].to_s.strip.first(100),
            page: [[raw_filters[:page].to_i, 1].max, 10_000].min,
            date: allowed(:date, %w(all upcoming recent), "all"),
            category: raw_filters[:category].to_s.presence,
            komsiluk_id: raw_filters[:komsiluk_id].to_s.presence
          }
        end

        def tab
          filters[:tab]
        end

        def status_options
          case tab
          when "applications" then APPLICATION_STATUSES
          when "hours" then HOUR_STATUSES
          else STATUSES
          end
        end

        def total_count
          @total_count ||= case tab
                           when "applications" then application_scope.count
                           when "hours" then hour_scope.count
                           else proposal_count
                           end
        end

        def total_pages
          [(total_count.to_f / PER_PAGE).ceil, 1].max
        end

        def page
          [filters[:page], total_pages].min
        end

        def records
          @records ||= case tab
                       when "applications" then application_records
                       when "hours" then hour_records
                       else proposal_records
                       end
        end

        def counts
          @counts ||= {
            opportunities: Decidim::Bih::VolunteerOpportunity.where(organization:).pending_review
                          .distinct.count(Arel.sql(GROUP_KEY)),
            applications: Decidim::Bih::VolunteerSignup.where(organization:, review_status: "pending").count,
            hours: Decidim::Bih::VolunteerLog.where(organization:, status: "pending").count
          }
        end

        def category_options
          Decidim::Bih::VolunteeringTaxonomy.option_pairs(:categories)
        end

        def komsiluk_options
          @komsiluk_options ||= Decidim::Bih::LocalArea.where(organization:, kind: "komsiluk")
                                .order(:slug).map { |area| [area.translated_name, area.id] }
        end

        private

        attr_reader :raw_filters

        def status_values
          case allowed(:tab, TABS, "opportunities")
          when "applications" then APPLICATION_STATUSES
          when "hours" then HOUR_STATUSES
          else STATUSES
          end
        end

        def allowed(key, values, fallback)
          value = raw_filters[key].to_s
          values.include?(value) ? value : fallback
        end

        def opportunity_scope
          scope = Decidim::Bih::VolunteerOpportunity.where(organization:)
          scope = scope.where(category: filters[:category]) if filters[:category].present?
          scope = scope.where(komsiluk_id: filters[:komsiluk_id]) if filters[:komsiluk_id].present?
          scope = scope.where("decidim_bih_volunteer_opportunities.title ILIKE ?", "%#{Decidim::Bih::VolunteerOpportunity.sanitize_sql_like(filters[:q])}%") if filters[:q].present?
          case filters[:date]
          when "upcoming" then scope = scope.where(starts_at: Time.current..)
          when "recent" then scope = scope.where(starts_at: 30.days.ago..Time.current)
          end
          scope
        end

        def filtered_opportunities
          scope = opportunity_scope
          case filters[:status]
          when "pending" then scope.pending_review
          when "needs_revision" then scope.where(review_status: "needs_revision")
          when "approved" then scope.where(review_status: "approved")
          when "active" then scope.active
          when "inactive" then scope.where(active: false, review_status: "approved")
          when "rejected" then scope.where(review_status: "rejected")
          when "cancelled" then scope.where.not(cancelled_at: nil)
          else scope
          end
        end

        def proposal_count
          filtered_opportunities.reorder(nil).distinct.count(Arel.sql(GROUP_KEY))
        end

        def proposal_records
          rows = filtered_opportunities.reorder(nil)
                 .select(Arel.sql("#{GROUP_KEY} AS proposal_key, MAX(decidim_bih_volunteer_opportunities.id) AS representative_id, COUNT(*) AS term_count, MIN(CASE WHEN decidim_bih_volunteer_opportunities.starts_at >= CURRENT_TIMESTAMP THEN decidim_bih_volunteer_opportunities.starts_at END) AS next_start"))
                 .group(Arel.sql(GROUP_KEY))
                 .order(Arel.sql("MAX(CASE WHEN decidim_bih_volunteer_opportunities.review_status = 'pending' THEN 1 ELSE 0 END) DESC, MIN(decidim_bih_volunteer_opportunities.starts_at) ASC NULLS LAST, MIN(decidim_bih_volunteer_opportunities.id)"))
                 .limit(PER_PAGE).offset((page - 1) * PER_PAGE).to_a
          by_id = Decidim::Bih::VolunteerOpportunity.where(organization:, id: rows.map(&:representative_id)).index_by(&:id)
          rows.filter_map do |row|
            opportunity = by_id[row.representative_id.to_i]
            { opportunity:, term_count: row.term_count.to_i, next_start: row.next_start, key: row.proposal_key } if opportunity
          end
        end

        def application_scope
          scope = Decidim::Bih::VolunteerSignup.where(organization:)
                  .joins(:opportunity).merge(opportunity_scope)
          case filters[:task]
          when "review" then scope = scope.where(review_status: "pending")
          when "attendance"
            scope = scope.where(status: "going", review_status: ["approved", "automatic"])
          end
          scope = scope.where(review_status: filters[:status]) if APPLICATION_STATUSES.include?(filters[:status]) && filters[:status] != "all"
          scope
        end

        def application_records
          application_scope.includes(:user, :opportunity)
            .order(Arel.sql("CASE WHEN decidim_bih_volunteer_signups.review_status = 'pending' THEN 0 ELSE 1 END"), created_at: :asc, id: :asc)
            .limit(PER_PAGE).offset((page - 1) * PER_PAGE).to_a
        end

        def hour_scope
          scope = Decidim::Bih::VolunteerLog.where(organization:)
                  .joins(:opportunity).merge(opportunity_scope)
          # Pending claims remain visible even when the opportunity is inactive.
          scope = scope.where(status: filters[:status]) if %w(pending approved rejected).include?(filters[:status])
          scope
        end

        def hour_records
          hour_scope.includes(:user, :opportunity)
            .order(Arel.sql("CASE WHEN decidim_bih_volunteer_logs.status = 'pending' THEN 0 ELSE 1 END"), created_at: :asc, id: :asc)
            .limit(PER_PAGE).offset((page - 1) * PER_PAGE).to_a
        end
      end
    end
  end
end
