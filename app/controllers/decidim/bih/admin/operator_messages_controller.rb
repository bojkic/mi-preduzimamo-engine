# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # Operator messages with an optional, previewed messaging app copy.
      class OperatorMessagesController < Decidim::Bih::Admin::ApplicationController
        CASE_PERMISSION = :operator_message_send
        GENERAL_SUPPORT_PERMISSION = :general_support_message_send
        REPORT_CONTEXT_TYPE = "report"
        REWARD_FULFILLMENT_CONTEXT_TYPE = "reward_fulfillment"
        ORGANIZATION_SPENDING_REQUEST_CONTEXT_TYPE = "organization_spending_request"
        PARTNER_PROFILE_CONTEXT_TYPE = "partner_profile"
        PARTNER_MEMBERSHIP_CONTEXT_TYPE = "partner_membership"
        VOLUNTEER_OPPORTUNITY_CONTEXT_TYPE = "volunteer_opportunity"
        VOLUNTEER_LOG_CONTEXT_TYPE = "volunteer_log"

        before_action :require_message_permission!

        def new
          @message_context = message_context if context_requested?
          return redirect_context_missing if context_requested? && @message_context.blank?

          @message_context_type = context_type if @message_context
          @message_context_label = message_context_label(@message_context) if @message_context
          @recipient = recipient_for_message
          return redirect_context_recipient_missing if context_requested? && @recipient.blank?

          @query = params[:q].to_s.strip
          @results = @query.present? ? search_users(@query) : []
          @subject = params[:subject].to_s
          @body = params[:body].to_s
        end

        # rubocop:disable Metrics/CyclomaticComplexity
        # -- a flat, ordered sequence of refusals. The ORDER is the
        # contract (context, recipient, preview, review, dispatch guard);
        # folding it into helpers would hide which refusal comes first.
        def create
          context = message_context if context_requested?
          return redirect_context_missing if context_requested? && context.blank?

          recipient = recipient_for_message(context:)
          if recipient.nil?
            flash[:alert] = t(".recipient_missing")
            return redirect_to new_operator_message_path
          end

          return if handle_delivery_request(recipient: recipient, context: context)

          unless ActiveModel::Type::Boolean.new.cast(params[:message_reviewed])
            return render_message_form_error(
              t("decidim.bih.admin.operator_messages.new.review_required"),
              context:,
              recipient:
            )
          end

          # The dispatch-time recheck. Additive: the review checkbox above and
          # the signed preview token in #handle_delivery_request both still
          # run, and this re-asks authorization, the recipient's availability
          # and the preview's freshness from state as it is NOW.
          return unless operator_dispatch_allowed?(recipient:, context:)

          deliver_operator_message(recipient:, context:)
        rescue ActiveRecord::RecordInvalid => e
          render_message_form_error(e.record.errors.full_messages.to_sentence.presence || t(".invalid"), context:, recipient:)
        end
        # rubocop:enable Metrics/CyclomaticComplexity

        private

        def deliver_operator_message(recipient:, context:)
          Decidim::Bih::OperatorMessenger.call(
            organization: current_organization,
            sender: current_user,
            recipient:,
            subject: params[:subject],
            body: params[:body],
            context:,
            permission: message_permission,
            external_notification: @external_notification
          )
          flash[:notice] = t("decidim.bih.admin.operator_messages.create.sent")
          redirect_after_send(recipient:, context:)
        end

        def handle_delivery_request(recipient:, context:)
          if params[:delivery_preview] == "1"
            preview_delivery(context: context, recipient: recipient)
            return true
          end
          return false unless external_copy?

          unless valid_delivery_preview?(recipient: recipient, context: context)
            render_message_form_error(t("decidim.bih.account_channels.operator.preview_required"), context: context, recipient: recipient)
            return true
          end
          @external_notification = notification_attributes(context: context)
          false
        end

        def external_copy?
          params[:external_copy] == "1"
        end

        def notification_topic(context)
          context.is_a?(Decidim::Bih::Report) ? "report_updates" : "community_news"
        end

        # The REGISTRY key, which the topic cannot stand in for: a case-bound
        # operator message becomes the report's own case message to its author
        # (OperatorMessenger hands the very same intent to ReportCaseMessageJob),
        # while an unbound one is an operator direct message.
        def notification_message_class(context)
          context.is_a?(Decidim::Bih::Report) ? "report.case_message_to_author" : "operator.direct_message"
        end

        def notification_text
          [params[:subject].to_s.strip, params[:body].to_s.strip].compact_blank.join("\n\n")
        end

        def notification_template(context)
          resolver = AccountNotifications.template_resolver
          return unless resolver

          resolver.call(topic: notification_topic(context), text: notification_text,
                        reference: context.respond_to?(:reference) ? context.reference : nil,
                        status: context.is_a?(Decidim::Bih::Report) ? ReportStatusPresenter.label(context) : nil)
        end

        def notification_attributes(context:)
          preview = delivery_verifier.verified(params[:delivery_token], purpose: "operator_delivery")
          {
            topic: notification_topic(context), text: notification_text,
            template: notification_template(context),
            message_class: notification_message_class(context),
            deduplication_key: "operator-copy:#{preview.fetch("nonce")}"
          }
        end

        def delivery_verifier
          Rails.application.message_verifier("bih_operator_delivery_preview")
        end

        def preview_digest(recipient:, context:)
          Digest::SHA256.hexdigest(JSON.generate([
                                                   current_organization.id, current_user.id, recipient.id,
                                                   context&.class&.name, context&.id, notification_topic(context),
                                                   notification_text, notification_template(context)
                                                 ]))
        end

        def valid_delivery_preview?(recipient:, context:)
          token = delivery_verifier.verified(params[:delivery_token], purpose: "operator_delivery")
          token.is_a?(Hash) && token["digest"] == preview_digest(recipient: recipient, context: context) && token["nonce"].present?
        end

        def preview_delivery(context:, recipient:)
          response.headers["Cache-Control"] = "no-store"
          response.headers["Referrer-Policy"] = "same-origin"
          draft = OperatorMessage.new(organization: current_organization, sender: current_user, recipient: recipient,
                                      subject: params[:subject], body: params[:body])
          return render_message_form_error(draft.errors.full_messages.to_sentence, context: context, recipient: recipient) unless draft.valid?

          @delivery_preview = AccountNotifications.preview(user: recipient, organization: current_organization,
                                                           topic: notification_topic(context), text: notification_text,
                                                           template: notification_template(context))
          @delivery_token = delivery_verifier.generate(
            { "digest" => preview_digest(recipient: recipient, context: context), "nonce" => SecureRandom.uuid },
            purpose: "operator_delivery", expires_in: 10.minutes
          )
          @delivery_template = notification_template(context)
          @composer = build_composer(context: context, recipient: recipient)
          render_message_form_error(nil, context: context, recipient: recipient, status: :ok)
        end

        # ---- the shared composer -------------------------------------------

        def build_composer(context:, recipient:)
          message_class = notification_message_class(context)
          channels = Array(@delivery_preview && @delivery_preview[:channels]).map(&:to_s)
          {
            content_plan: Decidim::Bih::Messaging::ComposerPlan.for(
              message_class:,
              channels: channels.presence,
              contents: composer_contents(channels)
            ),
            estimate: composer_estimate(message_class:, recipient:, channels:),
            guard: compose_time_guard(recipient:, channels:),
            # Only inside an authorized case, and only for a role that already
            # holds that case's read permission — which #require_message_permission!
            # has already demanded before this action ran.
            recipient_label: case_recipient_label(context:, recipient:)
          }
        end

        def composer_contents(channels)
          display = @delivery_template.is_a?(Hash) ? @delivery_template[:display_text] : nil
          channels.index_with { |channel| channel == "whatsapp" ? (display || notification_text) : notification_text }
        end

        # One recipient, but counted the SAME way a thousand would be: through
        # Policy decisions, never through a stored preference key.
        def composer_estimate(message_class:, recipient:, channels:)
          return nil if recipient.nil?

          Decidim::Bih::Messaging::AudienceEstimate.for(
            organization: current_organization, message_class:,
            recipient_ids: [recipient.id], channels: channels.presence
          )
        rescue StandardError => e
          Rails.logger.warn("[bih] operator composer estimate unavailable: #{e.class}")
          nil
        end

        def case_recipient_label(context:, recipient:)
          return nil if context.nil? || recipient.nil?

          permission = context_read_permission(context_type)
          return nil unless permission && bih_allowed?(permission)

          recipient.name.presence || recipient.nickname
        end

        def compose_time_guard(recipient:, channels:)
          Decidim::Bih::Messaging::DispatchGuard.evaluate(
            authorized: bih_allowed?(message_permission),
            governance_current: true,
            preview_fresh: true,
            preview_matches: true,
            audience_unchanged: recipient_available?(recipient),
            expired: false,
            channel_ready: !external_copy? || channels.any?
          )
        end

        # ---- the dispatch-time recheck --------------------------------------

        def operator_dispatch_allowed?(recipient:, context:)
          result = Decidim::Bih::Messaging::DispatchGuard.evaluate(
            authorized: bih_allowed?(message_permission),
            governance_current: true,
            preview_fresh: !external_copy? || delivery_token_live?,
            preview_matches: !external_copy? || valid_delivery_preview?(recipient: recipient, context: context),
            audience_unchanged: recipient_available?(recipient),
            expired: false,
            channel_ready: true
          )
          return true if result.allowed?

          @dispatch_guard = result
          render_message_form_error(
            t("decidim.bih.admin.composer.blockers.#{result.blockers.first}"),
            context: context, recipient: recipient
          )
          false
        end

        # The signed token carries its own ten-minute expiry, so a token that
        # no longer verifies is exactly an expired preview.
        def delivery_token_live?
          delivery_verifier.verified(params[:delivery_token], purpose: "operator_delivery").is_a?(Hash)
        end

        def recipient_available?(recipient)
          return false if recipient.nil?

          !recipient.reload.deleted? && !recipient.blocked?
        rescue ActiveRecord::RecordNotFound
          false
        end

        def require_message_permission!
          require_bih_permission!(message_permission)
          read_permission = context_read_permission(context_type)
          require_bih_permission!(read_permission) if read_permission
        end

        def message_permission
          context_requested? ? CASE_PERMISSION : GENERAL_SUPPORT_PERMISSION
        end

        def context_requested?
          params[:context_type].present? || params[:context_id].present?
        end

        def context_type
          params[:context_type].to_s
        end

        def message_context
          case context_type
          when REPORT_CONTEXT_TYPE
            Decidim::Bih::Report.where(organization: current_organization).find_by(id: params[:context_id])
          when REWARD_FULFILLMENT_CONTEXT_TYPE
            Decidim::Bih::Goodwill::RewardFulfillment.where(organization: current_organization).find_by(id: params[:context_id])
          when ORGANIZATION_SPENDING_REQUEST_CONTEXT_TYPE
            Decidim::Bih::Goodwill::OrganizationSpendingRequest.where(organization: current_organization).find_by(id: params[:context_id])
          when PARTNER_PROFILE_CONTEXT_TYPE
            Decidim::Bih::PartnerProfile.where(organization: current_organization).find_by(id: params[:context_id])
          when PARTNER_MEMBERSHIP_CONTEXT_TYPE
            Decidim::Bih::PartnerMembership.where(organization: current_organization).find_by(id: params[:context_id])
          when VOLUNTEER_OPPORTUNITY_CONTEXT_TYPE
            Decidim::Bih::VolunteerOpportunity.where(organization: current_organization).find_by(id: params[:context_id])
          when VOLUNTEER_LOG_CONTEXT_TYPE
            Decidim::Bih::VolunteerLog.where(organization: current_organization).find_by(id: params[:context_id])
          end
        end

        def recipient_for_message(context: @message_context)
          case context
          when Decidim::Bih::Report, Decidim::Bih::VolunteerOpportunity
            return context.author
          when Decidim::Bih::Goodwill::OrganizationSpendingRequest
            return context.requested_by
          when Decidim::Bih::Goodwill::RewardFulfillment, Decidim::Bih::VolunteerLog,
               Decidim::Bih::PartnerMembership
            return context.user
          when Decidim::Bih::PartnerProfile
            return context.memberships.accepted.where(role: %w(owner manager)).includes(:user).first&.user
          end

          recipient_from_params
        end

        def users_scope
          Decidim::User
            .where(organization: current_organization, deleted_at: nil)
            .not_user_group
        end

        def recipient_from_params
          id = params[:recipient_id].presence || params[:id].presence
          return nil if id.blank?

          users_scope.find_by(id:)
        end

        def search_users(query)
          q = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
          users_scope
            .where("name ILIKE :q OR nickname ILIKE :q OR email ILIKE :q", q:)
            .order(:name, :nickname)
            .limit(20)
        end

        def redirect_after_send(recipient:, context:)
          return redirect_to context_redirect_path(context) if context

          redirect_to admin_bih_citizen_path(recipient)
        end

        def redirect_context_missing
          flash[:alert] = t(".context_missing")
          redirect_to admin_bih_reports_path
        end

        def redirect_context_recipient_missing
          flash[:alert] = t(".context_recipient_missing")
          redirect_to context_redirect_path(@message_context)
        end

        def context_redirect_path(context)
          case context
          when Decidim::Bih::Report
            admin_bih_report_path(reference: context.reference)
          when Decidim::Bih::Goodwill::RewardFulfillment
            goodwill_dashboard_path(anchor: "goodwill-reward-fulfillments")
          when Decidim::Bih::Goodwill::OrganizationSpendingRequest
            goodwill_dashboard_path(anchor: "goodwill-organization-spending")
          when Decidim::Bih::VolunteerOpportunity, Decidim::Bih::VolunteerLog
            admin_bih_volunteering_path
          when Decidim::Bih::PartnerProfile
            partner_profile_path(context)
          when Decidim::Bih::PartnerMembership
            memberships_partner_profile_path(context.partner_profile)
          else
            decidim_admin.root_path
          end
        end

        def context_read_permission(type)
          case type
          when REPORT_CONTEXT_TYPE
            :reports_read
          when REWARD_FULFILLMENT_CONTEXT_TYPE, ORGANIZATION_SPENDING_REQUEST_CONTEXT_TYPE
            :goodwill_dashboard_read
          when VOLUNTEER_OPPORTUNITY_CONTEXT_TYPE, VOLUNTEER_LOG_CONTEXT_TYPE
            :volunteering_roster_read
          when PARTNER_PROFILE_CONTEXT_TYPE, PARTNER_MEMBERSHIP_CONTEXT_TYPE
            :partner_profiles_manage
          end
        end

        def message_context_label(context)
          case context
          when Decidim::Bih::Report
            t("decidim.bih.admin.operator_messages.new.report_context", reference: context.reference)
          when Decidim::Bih::Goodwill::RewardFulfillment
            t("decidim.bih.admin.operator_messages.new.reward_fulfillment_context", id: context.id, reward: context.reward_key)
          when Decidim::Bih::Goodwill::OrganizationSpendingRequest
            t("decidim.bih.admin.operator_messages.new.organization_spending_request_context",
              id: context.id,
              profile: context.source_partner_profile.display_name)
          when Decidim::Bih::VolunteerOpportunity
            t("decidim.bih.admin.operator_messages.new.volunteer_opportunity_context", title: context.title)
          when Decidim::Bih::VolunteerLog
            t("decidim.bih.admin.operator_messages.new.volunteer_log_context", id: context.id, title: context.opportunity.title)
          when Decidim::Bih::PartnerProfile
            t("decidim.bih.admin.operator_messages.new.partner_profile_context", profile: context.display_name)
          when Decidim::Bih::PartnerMembership
            t(
              "decidim.bih.admin.operator_messages.new.partner_membership_context",
              profile: context.partner_profile.display_name,
              role: t("decidim.bih.partner_memberships.roles.#{context.role}")
            )
          end
        end

        def render_message_form_error(message, context:, recipient:, status: :unprocessable_entity)
          @message_context = context
          @message_context_type = context_type if context
          @message_context_label = message_context_label(context) if context
          @recipient = recipient
          @query = ""
          @results = []
          @subject = params[:subject].to_s
          @body = params[:body].to_s
          @form_errors = [message].compact
          flash.now[:alert] = message if message
          render :new, status: status
        end
      end
    end
  end
end
