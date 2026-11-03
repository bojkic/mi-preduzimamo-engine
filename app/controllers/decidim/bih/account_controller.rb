# frozen_string_literal: true

module Decidim
  module Bih
    # Private citizen setup overview. This page gathers account, verification,
    # Komšiluk and notification next steps without duplicating the wallet ledger
    # or exposing private profile data publicly.
    class AccountController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser
      include Decidim::UserProfile

      helper Decidim::PasswordsHelper
      helper_method :staff_notification_settings?

      def show
        return unless load_current_account_user

        build_account_page
      end

      def update
        return unless load_current_account_user

        @account = form(Decidim::AccountForm).from_params(account_params)
        Decidim::UpdateAccount.call(@account) do
          on(:ok) do |email_is_unconfirmed|
            flash[:notice] = if email_is_unconfirmed
                               t("account.update.success_with_email_confirmation", scope: "decidim")
                             else
                               t("account.update.success", scope: "decidim")
                             end

            bypass_sign_in(current_user)
            redirect_to account_overview_path(anchor: "osnovni-podaci")
          end

          on(:invalid) do |password|
            fetch_entered_password(password)
            build_summary
            flash.now[:alert] = t("account.update.error", scope: "decidim")
            render :show, status: :unprocessable_entity
          end
        end
      end

      def update_public_recognition
        return unless load_current_account_user

        Decidim::Bih::PublicRecognition.set_enabled!(@user, params[:enabled])
        enabled = Decidim::Bih::PublicRecognition.enabled_for?(@user)
        flash[:notice] = t(".success_#{enabled ? "enabled" : "disabled"}")
        redirect_to account_overview_path(anchor: "osnovni-podaci")
      end

      # Authenticated, organization-scoped self-service; no delivery side effect.
      def update_message_privacy
        return unless load_current_account_user

        allowed = ["allow_public_contact"]
        allowed << "email_on_assigned_proposals" if staff_notification_settings?
        allowed << "email_on_moderations" if @user.moderator?
        submitted = params.fetch(:message_privacy, ActionController::Parameters.new).permit(*allowed).to_h
        return head :unprocessable_entity unless submitted.values.all? { |value| %w(0 1).include?(value.to_s) }

        @user.with_lock do
          apply_message_privacy(submitted)
          apply_staff_registry
          @user.save!
        end
        redirect_to account_overview_path(anchor: "privatnost-poruka"), notice: t("decidim.bih.communication_settings.saved")
      end

      private

      def apply_message_privacy(submitted)
        if submitted.has_key?("allow_public_contact")
          @user.direct_message_types = submitted["allow_public_contact"] == "1" ? "all" : "followed-only"
        end
        %w(email_on_assigned_proposals email_on_moderations).each do |attribute|
          @user.public_send("#{attribute}=", submitted[attribute] == "1") if submitted.has_key?(attribute)
        end
      end

      def apply_staff_registry
        return unless @user.moderator?

        rows = Messaging::SettingsCatalogue.registry_rows(@user)
        registry = params.fetch(:staff_registry, ActionController::Parameters.new).permit(*rows.map { |row| row[:id].to_s }).to_h
        rows.each do |row|
          value = registry[row[:id].to_s]
          next unless %w(0 1).include?(value)

          @user.notification_settings = @user.notification_settings.merge(row[:id].to_s => value == "1")
        end
      end

      def staff_notification_settings?
        return true if @user.admin? || @user.moderator?

        %w(Decidim::ParticipatoryProcessUserRole Decidim::AssemblyUserRole).any? do |name|
          model = name.safe_constantize
          model && model.exists?(decidim_user_id: @user.id, role: "evaluator")
        end
      end

      def build_account_page
        build_summary
        @account = form(Decidim::AccountForm).from_model(@user)
        @account.password = nil
      end

      def build_summary
        @summary = Decidim::Bih::AccountSummary.new(
          organization: current_organization,
          user: @user
        )
      end

      def load_current_account_user
        @user = current_organization_user
        return true if @user

        flash[:alert] = t("decidim.bih.account.show.login_required")
        destination = Decidim::Bih.public_path("moj-nalog")
        CitizenReturnPath.store(session, organization: current_organization, path: destination) if request.get?
        redirect_to(decidim.new_user_session_path(redirect_url: destination))
        false
      end

      def account_params
        params[:user].to_unsafe_h
      end

      def fetch_entered_password(password)
        @account.password = password
      end
    end
  end
end
