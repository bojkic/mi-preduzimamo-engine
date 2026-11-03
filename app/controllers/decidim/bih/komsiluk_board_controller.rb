# frozen_string_literal: true

module Decidim
  module Bih
    class KomsilukBoardController < Decidim::ApplicationController
      include Decidim::Bih::RequiresKomsilukMembership
      helper Decidim::Bih::KomsilukBoardHelper
      ALLOWED_CATEGORIES = KomsilukPost::CATEGORIES.freeze
      PAGE_SIZE = 20
      BOARD_FILTERS = [:view, :cat, :origin, :status, :q, :page].freeze
      before_action :protect_board_response
      helper_method :board_verification_path, :board_filter_params, :board_list_path

      def index
        load_board
        @post ||= KomsilukPost.new(category: "general")
        @compose_open = params[:compose] == "1"
      end

      def show
        return unless load_readable_post

        prepare_detail
      end

      def publication
        scope = organization_posts.where(publication_key: params[:publication_key].to_s)
        @post = scope.find_by(komsiluk_id: @citizen_profile.komsiluk_id) || scope.find_by(decidim_user_id: current_organization_user.id)
        return unavailable unless @post

        prepare_detail
        render :show
      end

      def edit
        return unless load_own_post
        return unavailable unless @post.editable_by?(current_organization_user)

        prepare_detail
      end

      def create
        @form_input = post_params
        attrs = public_attributes
        @post = KomsilukPost.new(**attrs, category: attrs[:category].presence || "general", origin: "citizen")
        publication_key = verified_publication_key
        existing = organization_posts.find_by(decidim_user_id: current_organization_user.id, publication_key:) if publication_key
        return redirect_to(decidim_bih.komsiluk_board_path(existing, board_filter_params), status: :see_other) if existing

        prepare_photo
        return failed_form if @input_errors.any?

        result = Komsiluk::PostCreator.new(organization: current_organization, author: current_organization_user,
                                           komsiluk: @citizen_profile.komsiluk).call(**attrs, photo: @photo_draft&.photo&.blob, publication_key:)
        @post = result.post
        if result.status == :created
          @photo_draft&.destroy!
          flash[:board_draft_clear] = true
          redirect_to decidim_bih.komsiluk_board_path(@post, board_filter_params), notice: t("decidim.bih.komsiluk_board.create.success"), status: :see_other
        else
          flash.now[:alert] = t("decidim.bih.komsiluk_board.create.#{result.status == :rate_limited ? "rate_limited" : "failed"}")
          failed_form
        end
      rescue KomsilukPhotoDraft::Invalid
        @post.errors.add(:photo, t("decidim.bih.boards.errors.photo"))
        failed_form
      rescue KomsilukPost::StaleRevision
        @form_input.delete(:publication_token)
        @post.errors.add(:base, t("decidim.bih.boards.errors.expired_form"))
        failed_form
      end

      def update
        return unless load_own_post
        return unavailable unless @post.editable_by?(current_organization_user)

        @form_input = post_params
        attrs = public_attributes
        prepare_photo
        return failed_form(editing: true) if @input_errors.any?

        @post.correct!(by: current_organization_user, attributes: attrs,
                       expected_revision: @form_input[:content_revision], notify: @form_input[:notify] == "1",
                       photo_blob: @photo_draft&.photo&.blob, remove_photo: @form_input[:remove_photo] == "1")
        @photo_draft&.destroy!
        flash[:board_draft_clear] = true
        redirect_to decidim_bih.komsiluk_board_path(@post, board_filter_params), notice: t("decidim.bih.boards.updated"), status: :see_other
      rescue KomsilukPost::StaleRevision, ActiveRecord::StaleObjectError
        @post.reload
        @post.errors.add(:base, t("decidim.bih.boards.errors.stale"))
        failed_form(editing: true)
      rescue ActiveRecord::RecordInvalid => e
        if e.record.is_a?(KomsilukPost)
          validation_errors = e.record.errors.map { |item| [item.attribute, item.message] }
          @post.reload
          validation_errors.each { |attribute, message| @post.errors.add(attribute, message) }
        end
        failed_form(editing: true)
      rescue KomsilukPost::NotEditable
        redirect_to decidim_bih.komsiluk_board_path(@post, board_filter_params), alert: t("decidim.bih.boards.errors.stale"), status: :see_other
      rescue KomsilukPhotoDraft::Invalid
        @post.errors.add(:photo, t("decidim.bih.boards.errors.photo"))
        failed_form(editing: true)
      end

      def zatvori
        return unless load_own_post

        success = @post.close!(by: current_organization_user)
        flash[success ? :notice : :alert] = t("decidim.bih.komsiluk_board.zatvori.#{success ? "success" : "failed"}")
        redirect_to board_list_path, status: :see_other
      end

      def resolve
        return unless load_own_post

        success = @post.resolve!(by: current_organization_user, outcome: params[:outcome].to_s)
        flash[success ? :notice : :alert] = t("decidim.bih.komsiluk_board.zatvori.#{success ? "success" : "failed"}")
        redirect_to decidim_bih.komsiluk_board_path(@post, board_filter_params), status: :see_other
      end

      def prijavi
        @post = organization_posts.visible.for_komsiluk(@citizen_profile.komsiluk_id).find_by(id: params[:id])
        return unavailable unless @post
        return redirect_to(board_list_path, alert: t("decidim.bih.komsiluk_board.prijavi.own_post")) if @post.decidim_user_id == current_organization_user.id

        result = @post.flag!(current_organization_user)
        flash[result == :already_flagged ? :alert : :notice] = t("decidim.bih.komsiluk_board.prijavi.#{result == :flagged ? "success" : result}")
        redirect_to board_list_path, status: :see_other
      end

      def help
        if params[:withdraw] == "1"
          @post = organization_posts.joins(:help_responses).where(decidim_bih_komsiluk_help_responses: { user_id: current_organization_user.id }).find_by(id: params[:id])
          return unavailable unless @post
        else
          return unless load_readable_post
          return unavailable if linked_public_source_updating?
        end

        result = Komsiluk::HelpResponses.call(post: @post, user: current_organization_user, withdraw: params[:withdraw] == "1")
        flash[result ? :notice : :alert] = t("decidim.bih.boards.help.#{result ? "saved" : "unavailable"}")
        redirect_to(@post.komsiluk_id == @citizen_profile.komsiluk_id ? decidim_bih.komsiluk_board_path(@post, board_filter_params) : board_list_path, status: :see_other)
      end

      def photo
        return unless load_readable_post
        return unavailable if linked_public_source_updating?
        return unavailable unless (@post.current? || @post.decidim_user_id == current_organization_user.id) && @post.photo.attached?

        send_private_photo(@post.photo)
      end

      def draft_photo
        draft = KomsilukPhotoDraft.where(organization: current_organization, user: current_organization_user).where("expires_at > ?", Time.current).find_by(id: params[:draft_id])
        return head(:not_found) unless draft

        send_private_photo(draft.photo)
      rescue KomsilukPhotoDraft::Invalid
        head :not_found
      end

      private

      def linked_public_source_updating?
        view_context.board_public_source_state(@post)[:updating]
      end

      def organization_posts
        KomsilukPost.where(decidim_organization_id: current_organization.id)
      end

      def load_board
        @category_filter = params[:cat].to_s.presence_in(ALLOWED_CATEGORIES)
        @origin_filter = params[:origin].to_s.presence_in(KomsilukPost::ORIGINS)
        @status_filter = params[:status].to_s.presence_in(KomsilukPost::STATUSES)
        @query = params[:q].to_s.strip.first(120)
        @mine = params[:view] == "mine"
        scope = @mine ? organization_posts.where(decidim_user_id: current_organization_user.id) : organization_posts.visible.for_komsiluk(@citizen_profile.komsiluk_id)
        scope = scope.where(category: @category_filter) if @category_filter
        scope = scope.where(origin: @origin_filter) if @origin_filter
        if @mine && @status_filter
          scope = case @status_filter
                  when "open" then scope.visible
                  when "expired" then scope.where(status: "expired").or(scope.where(status: "open", expires_at: ..Time.current))
                  else scope.where(status: @status_filter)
                  end
        end
        if @query.present?
          pattern = "%#{KomsilukPost.sanitize_sql_like(@query)}%"
          scope = scope.where("title ILIKE :pattern OR body ILIKE :pattern", pattern:)
        end
        @posts = scope.includes(:author, :komsiluk, photo_attachment: :blob).order(created_at: :desc, id: :desc).page(params[:page]).per(PAGE_SIZE)
        @total_posts = @posts.total_count
        @priority_posts = []
        if !@mine && @category_filter.nil? && @origin_filter.nil? && @query.blank? && params[:page].to_i <= 1
          current_posts = organization_posts.visible.for_komsiluk(@citizen_profile.komsiluk_id)
          @priority_posts = current_posts.where(category: %w(lost_pet safety)).or(current_posts.where(origin: "city_service"))
                                         .order(created_at: :desc, id: :desc).limit(3)
        end
        @posts_today = organization_posts.where(decidim_user_id: current_organization_user.id, created_at: Time.current.beginning_of_day..).count
        prepare_shared_context
      end

      def load_readable_post
        @post = organization_posts.includes(:author, :komsiluk).find_by(id: params[:id])
        unless @post && (@post.komsiluk_id == @citizen_profile.komsiluk_id || @post.decidim_user_id == current_organization_user.id)
          # A prior voluntary offer may still be withdrawn after moving, while
          # the former board's title, author and body remain inaccessible.
          @withdrawal_post_id = @post.id if action_name == "show" && @post && @post.help_responses.active.exists?(user: current_organization_user)
          return unavailable
        end

        true
      end

      def load_own_post
        @post = organization_posts.find_by(id: params[:id], decidim_user_id: current_organization_user.id)
        return unavailable unless @post

        true
      end

      def prepare_detail
        @can_read_content = @post.current? || @post.decidim_user_id == current_organization_user.id
        @help_response = @post.help_responses.find_by(user: current_organization_user)
        if @post.decidim_user_id == current_organization_user.id && @post.help_enabled?
          # Only people who explicitly offered help are shown to the author.
          # Withdrawn responses and unrelated board membership never appear.
          @helpers = @post.help_responses.active.joins(:user)
                          .where(decidim_users: { blocked: false, deleted_at: nil })
                          .where.not(decidim_users: { confirmed_at: nil }).includes(:user)
                          .order(created_at: :desc, id: :desc).page(params[:help_page]).per(20)
        end
        prepare_shared_context
      end

      def prepare_shared_context
        @can_write = sms_authorization_granted?
        @publication_token = @form_input&.[](:publication_token).presence || Rails.application.message_verifier(:komsiluk_post_submission).generate(
          { organization_id: current_organization.id, user_id: current_organization_user.id, komsiluk_id: @citizen_profile.komsiluk_id,
            key: SecureRandom.uuid }, expires_in: 2.hours
        )
        @topic_enabled = TopicPreferences.enabled?(current_organization_user, topic: :neighborhood_info)
        @board_context_links = []
        provider = Decidim::Bih.komsiluk_board_context_provider
        return unless provider.respond_to?(:call)

        context_post = @post if @can_read_content && @post.current? && @post.komsiluk_id == @citizen_profile.komsiluk_id
        @board_context_links = Array(provider.call(organization: current_organization, user: current_organization_user,
                                                   komsiluk: @citizen_profile.komsiluk, post: context_post)).first(8)
      rescue StandardError => e
        Rails.logger.warn("[KomsilukBoard] context unavailable: #{e.class}")
      end

      def post_params
        params.require(:komsiluk_post).permit(:category, :title, :body, :expires_at, :photo, :photo_draft_token, :remove_saved_photo,
                                              :remove_photo, :content_revision, :notify, :help_enabled, :publication_token,
                                              activity: [:starts_at, :place_label, :action_url])
      end

      def public_attributes
        @input_errors = []
        category = @form_input[:category].presence || "general"
        activity = @form_input[:activity].to_h.stringify_keys.transform_values { |value| value.to_s.strip.first(300) }
        starts_at = parse_board_date(activity["starts_at"])
        activity["starts_at"] = starts_at&.iso8601 if activity.has_key?("starts_at")
        expires_at = parse_board_date(@form_input[:expires_at])
        if expires_at && (expires_at <= Time.current || expires_at > KomsilukPost::OPTIONAL_EXPIRY_MAX_DAYS.days.from_now)
          @input_errors << [:expires_at, t("decidim.bih.boards.errors.expiry")]
        end
        { category:, title: @form_input[:title].to_s, body: @form_input[:body].to_s, expires_at:,
          details: { "activity" => activity.compact_blank, "help_enabled" => @form_input[:help_enabled] == "1" } }
      end

      def verified_publication_key
        return nil if @form_input[:publication_token].blank?

        payload = Rails.application.message_verifier(:komsiluk_post_submission).verified(@form_input[:publication_token])
        raise KomsilukPost::StaleRevision unless payload.is_a?(Hash)

        # JSON serializers round-trip signed hash keys as strings.
        value = payload.symbolize_keys
        unless value[:organization_id] == current_organization.id && value[:user_id] == current_organization_user.id && value[:komsiluk_id] == @citizen_profile.komsiluk_id
          raise KomsilukPost::StaleRevision
        end

        value[:key]
      end

      def parse_board_date(value)
        return nil if value.blank?

        Time.find_zone!("Europe/Sarajevo").parse(value.to_s)
      rescue ArgumentError, TypeError
        @input_errors << [:expires_at, t("decidim.bih.boards.errors.date")]
        nil
      end

      def prepare_photo
        token = @form_input[:photo_draft_token]
        @photo_draft = KomsilukPhotoDraft.for_owner!(token:, organization: current_organization, user: current_organization_user) if token.present?
        if @form_input[:remove_saved_photo] == "1"
          @photo_draft&.destroy!
          @photo_draft = nil
        end
        return if @form_input[:photo].blank?

        previous = @photo_draft
        @photo_draft = KomsilukPhotoDraft.store!(organization: current_organization, user: current_organization_user, upload: @form_input[:photo])
        previous&.destroy!
      end

      def failed_form(editing: false)
        Array(@input_errors).each { |field, message| @post.errors.add(field, message) }
        if editing
          prepare_detail
          render :edit, status: :unprocessable_entity
        else
          load_board
          @compose_open = true
          render :index, status: :unprocessable_entity
        end
      end

      def unavailable
        @post = nil
        render :unavailable, status: :not_found
        false
      end

      def board_filter_params
        params.permit(*BOARD_FILTERS).to_h
      end

      def board_list_path
        decidim_bih.komsiluk_board_index_path(board_filter_params)
      end

      def board_verification_path
        destination = decidim_bih.komsiluk_board_index_path(compose: 1)
        return decidim_verifications.authorizations_path(redirect_url: destination) unless Decidim::Bih.phone_first_registration

        authorization = Decidim::Authorization.find_by(user: current_organization_user, name: "sms")
        return decidim_bih.phone_verification_path(redirect_url: destination) if authorization

        "#{Onboarding::NextStep.sms_new_path}?#{{ redirect_url: destination }.to_query}"
      end

      def protect_board_response
        response.set_header("Cache-Control", "private, no-store")
        response.set_header("X-Robots-Tag", "noindex, nofollow")
        response.set_header("Referrer-Policy", "no-referrer")
      end

      def send_private_photo(photo)
        return head(:not_found) unless photo.attached?

        response.set_header("X-Content-Type-Options", "nosniff")
        send_data photo.download, type: photo.content_type, disposition: "inline", filename: "komsiluk-photo"
      end
    end
  end
end
