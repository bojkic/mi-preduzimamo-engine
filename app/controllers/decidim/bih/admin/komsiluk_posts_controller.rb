# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class KomsilukPostsController < Decidim::Bih::Admin::ApplicationController
        before_action -> { require_bih_permission!(:komsiluk_posts_read) }, only: [:index]
        before_action -> { require_bih_permission!(:komsiluk_notification_policy_manage) }, only: [:update_notification_policy]
        before_action -> { require_bih_permission!(:komsiluk_posts_moderate) }, only: [:decide, :hide, :unhide]

        helper Decidim::Bih::KomsilukBoardHelper
        helper_method :moderation_filter_params, :board_effective_status, :board_mz_names, :board_active_filters

        def index
          if params[:tab] == "settings"
            require_bih_permission!(:komsiluk_notification_policy_manage)
            return redirect_to admin_bih_board_notice_settings_path
          end

          load_queue
        end

        def show
          @post = find_post
          return unless @post

          @delivery_only = !bih_allowed?(:komsiluk_posts_read, resource: @post)
          raise Decidim::ActionForbidden if @delivery_only && !(bih_allowed?(:broadcast_preview) && %w(staff city_service).include?(@post.origin))

          load_detail
        end

        def decide
          perform_decision(params[:decision])
        end

        # Compatibility actions retain the same CSRF and exact-version guards.
        def hide
          perform_decision("hide")
        end

        def unhide
          perform_decision("restore")
        end

        def update_notification_policy
          flash[:notice] = t("decidim.bih.komsiluk_notice_sources.settings_legacy")
          redirect_to admin_bih_board_notice_settings_path
        end

        private

        def perform_decision(action)
          @post = find_post
          return unless @post

          review = Decidim::Bih::Komsiluk::PostModeration.new(post: @post, actor: current_user, organization: current_organization).call(
            action:, reason: params[:reason], expected_version: params[:lock_version]
          )
          flash[:notice] = t("decidim.bih.admin.board_review.saved", status: t("decidim.bih.komsiluk_board.statuses.#{review.resulting_status}"))
          redirect_to admin_bih_komsiluk_posts_path(moderation_filter_params.merge(anchor: "komsiluk-posts-list"))
        rescue Decidim::Bih::Komsiluk::PostModeration::InvalidDecision => e
          flash.now[:alert] = t("decidim.bih.admin.board_review.errors.#{e.code}")
          @post.reload
          load_detail
          render :show, status: :unprocessable_entity
        end

        def find_post
          scope = accessible_posts
          scope = scope.or(KomsilukPost.where(organization: current_organization, origin: %w(staff city_service))) if action_name == "show" && bih_allowed?(:broadcast_preview)
          found = scope.find_by(id: params[:id])
          return found if found

          flash[:alert] = t("decidim.bih.admin.komsiluk_posts.not_found")
          target = bih_allowed?(:komsiluk_posts_read) ? admin_bih_komsiluk_posts_path(moderation_filter_params) : new_admin_bih_board_notice_path
          redirect_to target
          nil
        end

        def accessible_posts
          access.posts
        end

        def access
          @access ||= Decidim::Bih::Komsiluk::ModerationAccess.new(user: current_user, organization: current_organization)
        end

        def load_queue
          @queue = Decidim::Bih::Komsiluk::ModerationQueue.new(scope: accessible_posts, params:)
          @posts = @queue.posts
          @komsiluk_options = access.areas.order(Arel.sql("name->>'sr'"), :id).to_a
          if @queue.tab == "delivery"
            @delivery_operations = Decidim::Bih::Komsiluk::DeliveryOperations.new(
              organization: current_organization, actor: current_user, scope: @queue.filtered, page: params[:page]
            )
          end
        end

        def load_detail
          review_scope = @delivery_only ? @post.reviews.none : @post.reviews
          @reviews_total = review_scope.count
          @review_pages = [(@reviews_total.to_f / 25).ceil, 1].max
          @review_page = params[:history_page].to_i.clamp(1, @review_pages)
          @reviews = review_scope.includes(:reviewer).order(created_at: :desc, id: :desc).offset((@review_page - 1) * 25).limit(25)
          @review_links = []
          integration = Decidim::Bih::Komsiluk::PostModeration.integration
          if integration.respond_to?(:review_links) && bih_allowed?(:city_alerts_manage)
            @review_links = Array(integration.review_links(post: @post, user: current_user, organization: current_organization))
          end
        end

        def moderation_filter_params
          params.permit(:tab, :status, :category, :origin, :komsiluk_id, :q, :from, :to, :page).to_h.compact_blank
        end

        def board_active_filters
          @queue.filters.map do |key, value|
            label = { q: "search", komsiluk_id: "area" }.fetch(key, key)
            display = case key
                      when :category then t("decidim.bih.komsiluk_board.categories.#{value}")
                      when :origin then t("decidim.bih.admin.board_review.origins.#{value}")
                      when :komsiluk_id then @komsiluk_options.find { |area| area.id == value }&.translated_name || value
                      else value
                      end
            [t("decidim.bih.admin.board_review.#{label}"), display]
          end
        end

        def board_effective_status(post)
          return "expired" if post.status == "open" && post.expires_at && post.expires_at <= Time.current

          post.status
        end

        def board_mz_names(area)
          @mz_names ||= Decidim::Bih::LocalArea.mz.where(organization: current_organization).to_a.index_by(&:slug)
          slugs = (Array(area&.overlapping_mz_slugs) + [area&.primary_mz_slug]).compact_blank.uniq
          slugs.filter_map { |slug| @mz_names[slug]&.translated_name }
        end
      end
    end
  end
end
