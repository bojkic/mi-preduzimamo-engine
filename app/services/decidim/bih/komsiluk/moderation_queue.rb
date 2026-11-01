# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      class ModerationQueue
        PAGE_SIZE = 25
        TABS = %w(review published hidden archive all delivery).freeze
        VISIBLE_TABS = %w(review published hidden archive all).freeze
        ORIGINS = %w(citizen staff city_service legacy).freeze

        attr_reader :filters, :tab, :page, :total, :counts, :posts, :filtered

        def initialize(scope:, params:)
          @scope = scope
          @params = params
          @filters = normalized_filters
          @tab = selected_tab
          @filtered = filter_scope
          @counts = VISIBLE_TABS.index_with { |key| tab_scope(key).count }
          @total = @counts.fetch(@tab, 0)
          @page = params[:page].to_i.clamp(1, pages)
          @posts = if @tab == "delivery"
                     @scope.none
                   else
                     tab_scope(@tab).includes(:author, :komsiluk).order(Arel.sql("CASE WHEN review_state = 'pending' AND category IN ('safety', 'lost_pet') THEN 0 ELSE 1 END"),
                                                                        created_at: :desc, id: :desc)
                                    .offset((@page - 1) * PAGE_SIZE).limit(PAGE_SIZE)
                   end
        end

        # The dashboard counts exactly what the review tab lists: an expired
        # city notice that was held and never reviewed is no longer actionable.
        def self.needs_review(scope, now: Time.current)
          scope.where(review_state: "pending")
               .where("origin <> :city_origin OR (status IN (:active_statuses) AND (expires_at IS NULL OR expires_at > :now))",
                      city_origin: "city_service", active_statuses: %w(open hidden), now:)
        end

        def pages
          [(@total.to_f / PAGE_SIZE).ceil, 1].max
        end

        def query_params
          filters.merge(tab:, page:)
        end

        private

        def selected_tab
          requested = @params[:tab].to_s
          if requested.blank?
            requested = { "needs_review" => "review", "open" => "published", "closed" => "archive", "expired" => "archive",
                          "hidden" => "hidden", "all" => "all" }[@params[:status].to_s]
          end
          TABS.include?(requested) ? requested : "review"
        end

        def normalized_filters
          {
            q: @params[:q].to_s.strip[0, 80].presence,
            category: KomsilukPost::CATEGORIES.include?(@params[:category]) ? @params[:category] : nil,
            origin: ORIGINS.include?(@params[:origin]) ? @params[:origin] : nil,
            komsiluk_id: @params[:komsiluk_id].to_s.match?(/\A[1-9]\d*\z/) ? @params[:komsiluk_id].to_i : nil,
            from: iso_date(@params[:from]), to: iso_date(@params[:to])
          }.compact_blank
        end

        def iso_date(value)
          Date.iso8601(value.to_s).iso8601 if value.present?
        rescue ArgumentError
          nil
        end

        def filter_scope
          scope = @scope
          [:category, :origin, :komsiluk_id].each { |key| scope = scope.where(key => filters[key]) if filters[key] }
          if filters[:q]
            pattern = "%#{ActiveRecord::Base.sanitize_sql_like(filters[:q])}%"
            scope = scope.where("title ILIKE :q OR body ILIKE :q", q: pattern)
          end
          scope = scope.where(created_at: Date.iso8601(filters[:from]).in_time_zone.beginning_of_day..) if filters[:from]
          scope = scope.where(created_at: ..Date.iso8601(filters[:to]).in_time_zone.end_of_day) if filters[:to]
          scope
        end

        def tab_scope(key)
          case key
          when "review" then self.class.needs_review(@filtered)
          when "published" then @filtered.visible
          when "hidden" then @filtered.where(status: "hidden")
          when "archive" then @filtered.where("status IN ('closed', 'expired') OR (status = 'open' AND expires_at <= ?)", Time.current)
          else @filtered
          end
        end
      end
    end
  end
end
