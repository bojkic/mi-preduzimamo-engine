# frozen_string_literal: true

require "decidim/bih/mail_job_log_privacy"

# Includes jobs queued before this release under the default job class.
Rails.application.config.to_prepare do
  ActionMailer::MailDeliveryJob.log_arguments = false
end

if Gem.loaded_specs.has_key?("sidekiq")
  require "sidekiq"
  Sidekiq.configure_server do |config|
    handler = Decidim::Bih::MailJobLogPrivacy
    config.error_handlers.unshift(handler) unless config.error_handlers.include?(handler)
  end
end
