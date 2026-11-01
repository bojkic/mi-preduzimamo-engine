# frozen_string_literal: true

module Decidim
  module Bih
    # Compatibility reader for jobs serialized before durable board publishing.
    # It never resolves membership or creates a receipt. Only safely bound,
    # captured receipt IDs can enter the current notice dispatcher.
    class KomsilukPostNotificationJob < ChunkedBellJob
      self.log_arguments = false

      def perform(opts = {})
        options = opts.with_indifferent_access
        return replay_legacy_chunk(options) if options[:post_id].blank?

        post = KomsilukPost.find_by(id: options[:post_id])
        return retire("post_unavailable") unless post
        return retire("organization_changed") if options[:organization_id].present? && options[:organization_id].to_i != post.decidim_organization_id
        return retire("publication_uncaptured") if post.notification_capture_identity.blank?

        identity = options[:delivery_identity].presence || post.notification_capture_identity
        return retire("publication_changed") unless identity == post.notification_capture_identity

        Komsiluk::NoticePublishing.replay_captured!(post:, identity:)
      end

      private

      def replay_legacy_chunk(options)
        identity = options[:delivery_identity].presence
        ids = Array(options[:user_ids]).map(&:to_i).select(&:positive?).uniq
        organization = Decidim::Organization.find_by(id: options[:organization_id])
        return retire("legacy_capture_unavailable") unless identity && ids.any? && organization

        # A legacy user_ids array is only a restriction on an existing capture;
        # it cannot establish notice identity, lifecycle or publication audience.
        PlatformDelivery.where(organization:, decidim_user_id: ids, identity:, cancelled_at: nil)
                        .where.not(komsiluk_post_id: nil).where("expires_at > ?", Time.current)
                        .find_each do |receipt|
          post = receipt.komsiluk_post
          next unless post && post.decidim_organization_id == organization.id && post.notification_capture_identity == identity

          KomsilukNoticeDeliveryJob.perform_now(receipt.id)
        end
      end

      def retire(reason)
        Rails.logger.info("[komsiluk_delivery] legacy_job_retired reason=#{reason}")
        nil
      end
    end
  end
end
