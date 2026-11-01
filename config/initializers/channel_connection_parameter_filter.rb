# frozen_string_literal: true

Rails.application.config.filter_parameters += [:channel_confirmation, :channel_connection_command]
Rails.application.config.to_prepare do
  Decidim::User.include Decidim::Bih::ClearsChannelConnections
end
