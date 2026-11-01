# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      class BoardNoticesController < ApplicationController
        before_action -> { require_bih_permission!(:broadcast_preview) }
        before_action -> { require_bih_permission!(:komsiluk_notification_policy_manage) }, only: [:settings, :update_settings]
        helper_method :notice_text, :notice_input_datetime
        rescue_from Komsiluk::NoticeComposer::Refused, with: :refused

        def new
          @values = { category: "general", expires_at: 7.days.from_now, area_ids: [] }
          if params[:draft].present?
            intent = KomsilukSendIntent.find_by!(id: params[:draft], organization: current_organization, actor: current_user, kind: "publication")
            @values.merge!(intent.payload)
            if @values[:phone]
              @values.merge!(@values[:phone])
              old_url = Komsiluk::NoticePublishing.board_url(KomsilukPost.new(organization: current_organization, publication_key: intent.publication_key))
              [:text, :sms_text].each { |key| @values[key] = @values[key].to_s.delete_suffix(old_url).strip }
            end
          elsif params[:source_kind].present? || params[:source_id].present?
            @values.merge!(composer.source_prefill(kind: params[:source_kind], id: params[:source_id]).except(:details))
            @values.merge!(source_kind: params[:source_kind], source_id: params[:source_id])
          end
          load_areas
        end

        def preview
          @values = publication_params.to_h.symbolize_keys
          @preview = composer.preview_publication(@values)
          render :preview
        end

        def edit
          load_post
          @correction_context = composer.correction_context(post: @post)
          @values = @post.attributes.symbolize_keys.slice(:title, :body, :category, :expires_at)
          @values[:notify] = false
          if params[:draft].present?
            intent = KomsilukSendIntent.find_by!(id: params[:draft], organization: current_organization, actor: current_user, kind: "correction")
            @values.merge!(intent.payload.slice(:title, :body, :category, :expires_at, :notify)) if intent.payload[:post_id] == @post.id
          end
        end

        def preview_correction
          load_post
          @values = params.require(:notice).permit(:title, :body, :category, :expires_at, :notify).to_h.symbolize_keys
          @preview = composer.preview_correction(post: @post, attributes: @values)
          render :correction_preview
        end

        def phone
          load_post
          @values = { text: "#{@post.title}\n#{@post.body.to_s.truncate(600)}", sms_text: @post.title, channels: [],
                      mode: "fallback", expires_at: @post.expires_at || 1.day.from_now }
          if params[:draft].present?
            intent = KomsilukSendIntent.find_by!(id: params[:draft], organization: current_organization, actor: current_user, kind: "phone")
            @values.merge!(intent.payload) if intent.payload[:post_id] == @post.id
          end
          @delivery = Komsiluk::NoticePhonePolicy.summary(@post)
        end

        def preview_phone
          load_post
          @values = phone_params.to_h.symbolize_keys
          @preview = composer.preview_phone(post: @post, attributes: @values)
          render :preview
        end

        def confirm
          intent = composer.confirm!(params[:confirmation_token])
          phone_requested = intent.kind == "phone" || intent.payload[:phone].present?
          audit_operator_action!("komsiluk_notice_confirmed", permission: phone_requested ? "broadcast_send_viber" : "broadcast_send_bell",
                                                              resource: intent, metadata: { kind: intent.kind, phone_requested:, recipients_count: intent.recipients_count })
          post = KomsilukPost.find_by!(organization: current_organization, publication_key: intent.publication_key)
          message = if intent.kind == "correction"
                      t("decidim.bih.admin.board_correction.saved")
                    else
                      notice_text(intent.kind == "phone" ? "phone_confirmed" : "published")
                    end
          redirect_to admin_bih_komsiluk_post_path(post), notice: message
        end

        def settings
          @settings = Komsiluk::NoticePhonePolicy.sms_config(current_organization)
          load_phone_area_settings
        end

        def update_settings
          return update_area_holds if params.has_key?(:phone_policy)

          enabled = ActiveModel::Type::Boolean.new.cast(params.require(:sms).permit(:enabled)[:enabled])
          Setting.transaction do
            Setting.put(current_organization, Komsiluk::NoticePhonePolicy::NAMESPACE, :sms_enabled, enabled)
            audit_operator_action!("komsiluk_sms_policy_updated", permission: "komsiluk_notification_policy_manage",
                                                                  metadata: { enabled: })
          end
          redirect_to admin_bih_board_notice_settings_path, notice: notice_text("settings_saved")
        end

        private

        def update_area_holds
          values = params.require(:phone_policy).permit(area_ids: [])
          @phone_held_ids = values[:area_ids]
          Komsiluk::PhoneAreaHolds.save!(organization: current_organization, actor: current_user, komsiluk_ids: @phone_held_ids)
          redirect_to admin_bih_board_notice_settings_path, notice: t("decidim.bih.admin.phone_area_holds.saved")
        end

        def load_phone_area_settings
          @phone_areas = LocalArea.komsiluci.where(organization: current_organization).order(Arel.sql("name->>'sr'"), :id).to_a
          @phone_held_ids ||= Komsiluk::PhoneAreaHolds.snapshot(current_organization).fetch(:komsiluk_ids)
          legacy_ids = Komsiluk::UrgentNotificationPolicy.muted_komsiluk_ids_for(current_organization).map(&:to_i)
          @legacy_phone_areas = @phone_areas.select { |area| legacy_ids.include?(area.id) }
        end

        def notice_text(key, **)
          t("decidim.bih.admin.board_notices.#{key}", **)
        end

        def notice_input_datetime(value)
          return if value.blank?

          value.in_time_zone("Europe/Sarajevo")&.strftime("%Y-%m-%dT%H:%M") || value.to_s
        rescue ArgumentError, TypeError
          value.to_s
        end

        def composer
          @composer ||= Komsiluk::NoticeComposer.new(organization: current_organization, actor: current_user)
        end

        def load_post
          @post = KomsilukPost.find_by!(id: params[:id], organization: current_organization)
        end

        def load_areas
          @areas = LocalArea.where(organization: current_organization, kind: %w(komsiluk mz)).order(:kind, :slug).to_a
          @recent = KomsilukPost.where(organization: current_organization, origin: "staff").order(created_at: :desc).limit(10)
          @legacy = Broadcast.where(organization: current_organization).order(created_at: :desc).limit(20)
        end

        def publication_params
          params.require(:notice).permit(:title, :body, :category, :expires_at, :source_kind, :source_id, :text, :sms_text, :mode, :urgency_reason, area_ids: [], channels: [])
        end

        def phone_params
          params.require(:notice).permit(:text, :sms_text, :mode, :urgency_reason, :expires_at, :retry_failed, channels: [])
        end

        def refused(error)
          flash.now[:alert] = notice_text("reasons.#{error.message}", default: notice_text("blocked"))
          case action_name
          when "preview"
            @values ||= {}
            load_areas
            render :new, status: :unprocessable_entity
          when "preview_correction"
            begin
              @correction_context = composer.correction_context(post: @post)
              render :edit, status: :unprocessable_entity
            rescue Komsiluk::NoticeComposer::Refused
              redirect_to new_admin_bih_board_notice_path, alert: flash.now[:alert]
            end
          when "preview_phone"
            @delivery = Komsiluk::NoticePhonePolicy.summary(@post)
            render :phone, status: :unprocessable_entity
          when "confirm"
            intent = KomsilukSendIntent.find_signed(params[:confirmation_token], purpose: :komsiluk_send_confirmation)
            if intent && intent.organization == current_organization && intent.actor == current_user
              begin
                @preview = composer.view(intent)
              rescue Komsiluk::NoticeComposer::Refused, ActiveRecord::RecordNotFound
                return redirect_to new_admin_bih_board_notice_path, alert: flash.now[:alert]
              end
              @confirmation_refused = true
              render(intent.kind == "correction" ? :correction_preview : :preview, status: :unprocessable_entity)
            else
              redirect_to new_admin_bih_board_notice_path, alert: flash.now[:alert]
            end
          when "update_settings"
            @settings ||= Komsiluk::NoticePhonePolicy.sms_config(current_organization)
            load_phone_area_settings
            render :settings, status: :unprocessable_entity
          else
            redirect_to new_admin_bih_board_notice_path, alert: flash.now[:alert]
          end
        end
      end
    end
  end
end
