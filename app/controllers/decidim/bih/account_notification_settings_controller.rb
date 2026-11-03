# frozen_string_literal: true

module Decidim
  module Bih
    # The canonical citizen communication page.
    class AccountNotificationSettingsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser
      before_action :require_account!

      def show
        @user = current_organization_user
        @settings = Messaging::SettingsView.new(user: @user, organization: current_organization)
        @form ||= CommunicationSettingsForm.new
      end

      def update
        if obsolete_settings_request?
          show
          flash.now[:alert] = t("decidim.bih.communication_settings.screen_changed")
          return render :show, status: :unprocessable_entity
        end

        @user = current_organization_user
        @form = CommunicationSettingsForm.from_params(params).with_context(current_user: @user)
        # A local, not an instance variable: Decidim::Command#evaluate runs the
        # block with `instance_eval`, so `self` inside `on(...)` is the COMMAND.
        # An `@ivar` assigned there would never reach the view.
        saved = false
        UpdateCommunicationSettings.call(@form, @user) do
          on(:ok) { saved = true }
          on(:invalid) { saved = false }
        end

        if saved
          flash[:notice] = t("decidim.bih.communication_settings.saved")
          # 302, never 301: a cached permanent redirect would outlive a
          # rollback of this page.
          return redirect_to account_notification_settings_path
        end

        flash.now[:alert] = t("decidim.bih.communication_settings.invalid")
        @settings = Messaging::SettingsView.new(user: @user, organization: current_organization)
        # Re-render with what the citizen submitted, not with what the database
        # still holds: retyping a whole page of choices because one radio was
        # rejected is how a save gets abandoned.
        render :show, status: :unprocessable_entity
      end

      def test_message
        channel = params[:channel].to_s
        return head :unprocessable_entity unless AccountChannelStatus::CHANNELS.include?(channel)

        user = current_organization_user
        text = I18n.t("decidim.bih.account_channels.test.body", locale: user.locale)
        decision = AccountNotifications.preview_test(user: user, organization: current_organization, channel: channel, text: text)
        return redirect_to account_notification_settings_path, alert: t("decidim.bih.account_channels.test.unavailable") unless decision[:eligible]

        cache_key = "bih-channel-test:#{current_organization.id}:#{user.id}"
        return head :too_many_requests unless Rails.cache.write(cache_key, true, expires_in: 5.minutes, unless_exist: true)

        AccountNotifications.enqueue_test!(user: user, organization: current_organization, channel: channel, text: text)
        redirect_to account_notification_settings_path, notice: t("decidim.bih.account_channels.test.queued")
      end

      private

      def obsolete_settings_request?
        return true if params[:topic].present? || params[:channel].present?

        submitted = params[:communication_settings]
        return false if submitted.nil?
        return true unless submitted.respond_to?(:keys)

        (submitted.keys - TopicPreferences::TOPICS - ["rendered_rows"]).any?
      end

      def require_account!
        response.headers["Cache-Control"] = "no-store"
        response.headers["Referrer-Policy"] = "same-origin"
        return if current_organization_user

        destination = Decidim::Bih.public_path("moj-nalog/poruke")
        CitizenReturnPath.store(session, organization: current_organization, path: destination) if request.get?
        redirect_to decidim.new_user_session_path(redirect_url: destination)
      end
    end
  end
end
