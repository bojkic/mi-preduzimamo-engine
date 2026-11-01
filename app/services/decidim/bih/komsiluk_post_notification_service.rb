# frozen_string_literal: true

module Decidim
  module Bih
    # Compatibility entry point for new board publication. Recipients are
    # captured durably by NoticePublishing in the publication transaction.
    # Historical notices without that boundary never resolve a new audience.
    # Queued legacy calls retain their accepted keyword interface.
    class KomsilukPostNotificationService
      # @param post         [Decidim::Bih::KomsilukPost]
      # @param board_url    [String]  absolute URL to the board
      def self.call(post:, board_url:, proactive_delivery: true, delivery_identity: nil, delivery_expires_at: nil, delivery_context: {}) # rubocop:disable Metrics/ParameterLists
        new(post:, board_url:, proactive_delivery:, delivery_identity:, delivery_expires_at:, delivery_context:).call
      end

      # Old queued callers retain board_url/proactive_delivery keyword support.
      def initialize(post:, delivery_identity: nil, delivery_expires_at: nil, delivery_context: {}, **_legacy)
        @post = post
        @delivery_identity = delivery_identity
        @delivery_expires_at = delivery_expires_at
        @delivery_context = delivery_context
      end

      def call
        return if post.origin == "legacy"

        Komsiluk::NoticePublishing.publish!(post:, identity: delivery_identity, expires_at: delivery_expires_at, context: delivery_context)
      end

      private

      attr_reader :post, :delivery_identity, :delivery_expires_at, :delivery_context
    end
  end
end
