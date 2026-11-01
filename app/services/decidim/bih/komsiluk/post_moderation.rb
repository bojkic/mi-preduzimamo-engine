# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      class PostModeration
        class InvalidDecision < StandardError
          attr_reader :code

          def initialize(code)
            @code = code
            super(code.to_s)
          end
        end

        class << self
          attr_accessor :integration
        end

        def initialize(post:, actor:, organization:)
          @post = post
          @actor = actor
          @organization = organization
        end

        def call(action:, reason:, expected_version:)
          @action = action.to_s
          @reason = reason.to_s
          validate_choice!
          operation = -> { persist_decision(expected_version) }
          provider = self.class.integration
          return operation.call unless provider

          provider.around_decision(post: @post, actor: @actor, action: @action.to_sym, &operation)
        rescue ActiveRecord::StaleObjectError
          raise InvalidDecision, :stale
        end

        private

        def validate_choice!
          raise InvalidDecision, :invalid_action unless KomsilukPostReview::ACTIONS.include?(@action)
          raise InvalidDecision, :invalid_reason unless KomsilukPostReview::REASONS.include?(@reason)
          raise Decidim::ActionForbidden unless @post.organization == @organization &&
                                                OperatorAuthorization.allowed?(@actor, :komsiluk_posts_moderate, organization: @organization, resource: @post)
        end

        def persist_decision(expected_version)
          @post.with_lock do
            validate_choice!
            raise InvalidDecision, :stale if !expected_version.to_s.match?(/\A\d+\z/) || @post.lock_version != expected_version.to_i

            previous_status = @post.status
            apply_decision!
            review = KomsilukPostReview.create!(
              organization: @organization, post: @post, reviewer: @actor,
              action: @action, reason: @reason, previous_status:, resulting_status: @post.status,
              content_revision: @post.content_revision, flagged_count: @post.flagged_count
            )
            record_audit!(review)
            NoticePublishing.cancel_pending_for!(post: @post, reason: "hidden") if @action == "hide"
            self.class.integration&.after_decision(post: @post, actor: @actor, action: @action.to_sym)
            review
          end
        end

        def apply_decision!
          details = @post.details.deep_dup
          moderation = details.fetch("moderation", {}).merge("reviewed_flag_count" => @post.flagged_count)
          attributes = { review_state: "reviewed" }
          case @action
          when "keep"
            raise InvalidDecision, :hidden if @post.hidden?
          when "hide"
            moderation["previous_status"] = @post.status unless @post.hidden?
            attributes.merge!(status: "hidden", hidden_at: @post.hidden_at || Time.current)
          when "restore"
            raise InvalidDecision, :not_hidden unless @post.hidden?

            restored = restored_status
            raise InvalidDecision, :archived if restored == "open" && @post.body.blank?

            attributes.merge!(status: restored, hidden_at: nil)
          end
          details["moderation"] = moderation
          @post.update!(attributes.merge(details:))
        end

        def restored_status
          return "closed" if @post.closed_at.present?
          return "expired" if @post.expires_at && @post.expires_at <= Time.current

          prior = @post.details.dig("moderation", "previous_status")
          %w(closed expired).include?(prior) ? prior : "open"
        end

        def record_audit!(review)
          OperatorAuditEvent.record!(
            organization: @organization, actor: @actor,
            event_type: { "keep" => "komsiluk_post_reviewed", "hide" => "komsiluk_post_hidden", "restore" => "komsiluk_post_unhidden" }.fetch(@action),
            permission: "komsiluk_posts_moderate", role: OperatorAuthorization.role_for(@actor, :komsiluk_posts_moderate, organization: @organization),
            resource: @post, metadata: { review_id: review.id, reason: @reason, previous_status: review.previous_status,
                                         restored_status: review.resulting_status, content_revision: review.content_revision }
          )
        end
      end
    end
  end
end
