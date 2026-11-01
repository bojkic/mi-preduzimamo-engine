# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      class HelpResponses
        def self.call(post:, user:, withdraw: false)
          profile = CitizenProfile.find_by(user:, decidim_organization_id: post.decidim_organization_id)
          return false unless user.decidim_organization_id == post.decidim_organization_id
          return false unless withdraw || profile&.komsiluk_id == post.komsiluk_id
          return false if user.id == post.decidim_user_id

          created = false
          response = nil
          post.with_lock do
            if withdraw
              response = post.help_responses.find_by(user:)
              response&.update!(withdrawn_at: Time.current)
            elsif post.current? && post.help_enabled?
              response = post.help_responses.find_or_initialize_by(user:)
              created = response.new_record?
              response.update!(withdrawn_at: nil)
            end
          end
          notify_author(post) if created
          response.present?
        end

        def self.notify_author(post)
          Decidim::EventsManager.publish(
            event: "decidim.events.bih.komsiluk_help", event_class: KomsilukHelpEvent,
            resource: post.author, affected_users: [post.author], force_send: true,
            extra: { "board_url" => Engine.routes.url_helpers.komsiluk_board_url(post, host: post.organization.host, protocol: "https",
                                                                                       script_name: Decidim::Bih.normalized_public_mount_path),
                     "notification_topic" => "community_news" }
          )
        rescue StandardError => e
          Rails.logger.error("[KomsilukHelp] notification failed: #{e.class}")
        end
        private_class_method :notify_author
      end
    end
  end
end
