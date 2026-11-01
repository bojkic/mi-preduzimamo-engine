# frozen_string_literal: true

module Decidim
  module Bih
    class ChannelConnectionsController < Decidim::ApplicationController
      include Decidim::Bih::CurrentOrganizationUser
      before_action :private_response
      before_action :require_account
      rescue_from ChannelConnections::InvalidProof, with: :invalid_proof

      def index
        @channels = ChannelConnections::CHANNELS
        @challenge = ChannelConnectionChallenge.find_by(id: session[:channel_connection_challenge_id],
                                                        decidim_user_id: @user.id, decidim_organization_id: current_organization.id,
                                                        consumed_at: nil)
        @challenge = nil if @challenge && @challenge.expires_at <= Time.current
      end

      def create
        @challenge, @command = ChannelConnections.begin!(user: @user, organization: current_organization, channel: params[:channel])
        session[:channel_connection_challenge_id] = @challenge.id
        @channels = ChannelConnections::CHANNELS
        render :index
      end

      def confirm
        ChannelConnections.confirm!(user: @user, organization: current_organization,
                                    challenge_id: session[:channel_connection_challenge_id], confirmation: params[:channel_confirmation])
        session.delete(:channel_connection_challenge_id)
        redirect_to channel_connections_path, notice: t("decidim.bih.channel_connections.connected")
      end

      def destroy
        ChannelConnections.disconnect!(user: @user, organization: current_organization, channel: params[:channel])
        session.delete(:channel_connection_challenge_id)
        redirect_to channel_connections_path, notice: t("decidim.bih.channel_connections.disconnected")
      end

      private

      def private_response
        response.cache_control.replace(no_store: true, private: true)
        response.set_header("Referrer-Policy", Decidim::Bih::PRIVATE_PAGE_REFERRER_POLICY)
      end

      def require_account
        @user = current_organization_user
        redirect_to decidim.new_user_session_path unless @user
      end

      def invalid_proof
        redirect_to channel_connections_path, alert: t("decidim.bih.channel_connections.invalid")
      end
    end
  end
end
