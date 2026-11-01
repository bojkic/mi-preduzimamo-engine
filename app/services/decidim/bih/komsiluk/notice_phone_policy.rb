# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    module Komsiluk
      module NoticePhonePolicy
        CHANNELS = %w(viber whatsapp sms).freeze
        MODES = %w(fallback urgent_fallback urgent_sms_now).freeze
        NAMESPACE = "komsiluk_delivery"
        class << self
          attr_accessor :source_blocker, :source_dispatch_guard
        end

        module_function

        def configuration(organization)
          Setting.namespace_for(organization, NAMESPACE).stringify_keys
        end

        def area_held?(organization:, komsiluk_id:)
          PhoneAreaHolds.snapshot(organization).fetch(:komsiluk_ids).include?(komsiluk_id)
        end

        def sms_config(organization)
          settings = configuration(organization)
          { enabled: ActiveModel::Type::Boolean.new.cast(settings["sms_enabled"]) }
        end

        def template(text)
          AccountNotifications.template_resolver&.call(topic: "neighborhood_info", text:)&.deep_symbolize_keys
        end

        def readiness(organization:, channels:, mode:, text:)
          config = Config.infobip
          blockers = []
          blockers << "phone_channels_required" if channels.empty?
          blockers << "invalid_channel_plan" unless (channels - CHANNELS).empty? && channels == (CHANNELS & channels)
          blockers << "invalid_delivery_mode" unless MODES.include?(mode)
          blockers << "urgent_sms_required" if mode == "urgent_sms_now" && channels != ["sms"]
          blockers << "sms_requires_urgency" if channels.include?("sms") && mode == "fallback"
          blockers << "provider_unconfigured" unless config[:base_url].present? && config[:api_key].present?
          blockers << "provider_unavailable" if IntegrationHealth.instance.send_blocked?(provider: "infobip")
          if channels.include?("viber")
            blockers << "viber_unconfigured" if config[:viber_bm_sender].blank?
            blockers << "viber_approval_required" unless GovernanceApproval.current_for(organization, "viber_launch")
          end
          if channels.include?("whatsapp")
            blockers << "whatsapp_unconfigured" unless config[:messages_api_enabled] && config[:whatsapp_sender].present?
            blockers << "whatsapp_template_required" unless template(text)
          end
          if channels.include?("sms")
            sms = sms_config(organization)
            blockers << "sms_unconfigured" if config[:sms_sender].blank?
            blockers << "sms_policy_required" unless sms[:enabled]
          end
          blockers
        end

        def source_reason(post, user: nil)
          return unless post.display_origin == "city_service"
          return "source_review_required" unless source_blocker

          source_blocker.call(post:, user:)
        end

        def eligible(user:, organization:, channels:, template:, sms_text:, **_copy)
          return { channels: [], reason: "account_unavailable" } unless user.organization == organization && user.confirmed_at && !user.deleted? && !user.blocked?
          return { channels: [], reason: "topic_disabled" } unless TopicPreferences.enabled?(user, topic: :neighborhood_info)

          phone = VerifiedPhone.delivery_phone_for(user:, organization:)
          return { channels: [], reason: "verified_phone_required" } if phone.blank?

          digest = Messaging::SuppressionKey.digest(kind: :phone, value: phone)
          selected = channels.reject do |channel|
            Messaging::Suppression.blocking_for(organization:, provider: "infobip", channel:, destination_digest: digest).present?
          end
          selected -= ["whatsapp"] unless template
          selected -= ["sms"] if sms_text.blank?
          { channels: selected, reason: selected.empty? ? "transport_suppressed" : nil, destination_digest: digest }
        end

        # Settle reservations created by older confirmed intents; new SMS plans do not reserve a budget.
        def release_budget!(delivery)
          return if delivery.reserved_minor.zero? || delivery.budget_released_at

          payload = delivery.send_intent.phone_payload
          sms = payload.fetch(:sms)
          budget = KomsilukSmsBudget.find_by(organization: delivery.organization,
                                             budget_on: payload.fetch(:budget_on), currency: sms.fetch(:currency))
          budget&.with_lock { budget.update!(reserved_minor: [budget.reserved_minor - delivery.reserved_minor, 0].max) }
          delivery.update!(budget_released_at: Time.current)
        end

        def summary(post)
          identities = PlatformDelivery.where(komsiluk_post_id: related_posts(post).select(:id))
          phone = KomsilukPhoneDelivery.where(platform_delivery_id: identities.select(:id))
          attempts = Messaging::Attempt.where(intent_id: identities.select(:push_intent_id)).where(channel: "push")
          { audience: identities.distinct.count(:decidim_user_id), publication_receipts: identities.count,
            push_device_attempts: attempts.count, push_service_accepted: attempts.where.not(accepted_at: nil).count,
            push_outcomes: attempts.group(:status).count, inbox_created: identities.where.not(inbox_created_at: nil).count,
            push_queued: identities.where.not(push_queued_at: nil).count,
            browser_displayed: identities.where.not(browser_displayed_at: nil).count,
            inbox_read: identities.where.not(inbox_read_at: nil).count,
            cancelled: identities.where.not(cancelled_at: nil).count, phone: phone.group(:status).count,
            skipped: phone.where(status: "skipped").group(:reason).count }
        end

        def related_posts(post)
          scope = KomsilukPost.where(organization: post.organization)
          post.publication_key.present? ? scope.where(publication_key: post.publication_key) : scope.where(id: post.id)
        end
      end
    end
  end
end
