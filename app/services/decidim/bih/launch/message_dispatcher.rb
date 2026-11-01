# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # One platform-topic campaign message. The shared account dispatcher
      # chooses an eligible channel by content fit and cost and owns the claim,
      # final topic/transport checks and uncertain-delivery handling. SMS is
      # never an optional campaign channel. P11 retains its email-only variant.
      class MessageDispatcher
        # The split is declared twice on purpose and the two declarations are
        # cross-checked by rails_test/messaging_router_campaign_test.rb: here,
        # because this is the branch that runs, and in the registry
        # (`campaign.marketing_phone.message_keys`), because that is what the
        # router reads. Neither supersedes the other; disagreeing is the bug.
        MARKETING_KEYS = %w(p4 p5 p8 p9 p10).freeze

        # Optional campaign transports, selected automatically. NEVER SMS.
        MARKETING_CHANNELS = %w(email messenger instagram viber whatsapp).freeze

        def initialize(user, organization:)
          @user = user
          @organization = organization
        end

        def deliver(key, locale: :sr, edition: nil, **vars)
          @delivery_edition = edition
          return :undeliverable unless TopicPreferences.enabled?(user, topic: :platform_news)

          return deliver_marketing(key, locale:, **vars) if MARKETING_KEYS.include?(key.to_s)

          phone_result = deliver_phone(key, locale:, **vars) if phone_permitted?(key)
          return :phone if phone_result == true
          return :email if phone_result == :email
          return :undeliverable if phone_result == :uncertain
          return :email if email_permitted?(key) && deliver_email(key, locale:, **vars)

          :undeliverable
        end

        private

        attr_reader :user, :organization

        # Which registry class owns this key. Nil for a key no class claims,
        # which is how a caller learns the key is unknown rather than
        # discovering it by sending nothing.
        def message_class_for(key)
          Messaging::MessageClass.for_message_key(key)&.key
        end

        # The routed plan for a transactional key, or nil when this sender is
        # not enrolled/not routing — in which case every caller below keeps the
        # legacy body verbatim. Built once per #deliver: two group questions
        # must not be two settings reads and two policy evaluations.
        def transactional_plan(key)
          @transactional_plan ||= {}
          return @transactional_plan[key.to_s] if @transactional_plan.has_key?(key.to_s)

          @transactional_plan[key.to_s] = build_transactional_plan(key)
        end

        def build_transactional_plan(key)
          message_class = message_class_for(key)
          return nil if message_class.nil?
          return nil unless Messaging::Enrollment.routes?(organization:, message_class:)

          Messaging::Router.plan(
            message_class:, organization:, mode: Messaging::Enrollment.mode(organization:, message_class:),
            recipient: Messaging::RecipientContext.account(
              organization_id: organization.id, account_id: user.id, locale: organization.default_locale
            ),
            context: Messaging::ExternalCopyRouting.context_for(
              user:, organization:, requested: MARKETING_CHANNELS, deadline_at: nil, dedup_key: delivery_key(key)
            ).merge(notification_topic: "platform_news")
          )
        rescue StandardError => e
          Rails.logger.warn("[launch] routing #{key} for user #{user.id} fell back to the legacy body: #{e.class}")
          nil
        end

        # In legacy mode both answers are true and the order below is literally
        # the old `deliver_phone || deliver_email`. Enrollment can only ever
        # REMOVE a leg the plan did not permit; it can never add one, because
        # the leg has to exist in the registry entry first.
        def phone_permitted?(key)
          plan = transactional_plan(key)
          plan.nil? || !plan.group("external_copy").nil? || !plan.group("phone_chain").nil?
        end

        def email_permitted?(key)
          plan = transactional_plan(key)
          plan.nil? || !plan.group("email").nil?
        end

        # Existing campaign audit identity is one message key per citizen/org.
        # The shared intent uses the same identity, so neither repeated tasks nor
        # uncertain responses bypass channel consent or start another send chain.
        # Email is a first-class candidate in the same intent, not a second
        # independent send after an uncertain provider result.
        def delivery_key(key)
          ["launch", key, @delivery_edition.presence].compact.join(":")
        end

        def deliver_marketing(key, locale:, **vars)
          text = render_if_present(key, :viber, locale:, **vars)
          template = whatsapp_template_for(key, **vars)
          options = { user:, organization:, topic: :platform_news, text:, template:,
                      channels: marketing_channels(key) }
          return :undeliverable unless AccountNotifications.preview(**options)[:eligible]

          notification = AccountNotifications.enqueue!(**options, deduplication_key: delivery_key(key), enqueue_job: false, message_class: message_class_for(key))
          AccountNotifications.dispatch!(notification)
          return :undeliverable unless %w(accepted delivered).include?(notification.reload.status)

          notification.channels.include?("email") ? :email : :phone
        rescue StandardError => e
          Rails.logger.warn("[launch] marketing delivery #{key} for user #{user.id}: #{e.class}")
          :undeliverable
        end

        # Routing may narrow eligible transports; the durable intent still
        # rechecks the platform-news topic and destination suppression at send.
        def marketing_channels(key)
          message_class = message_class_for(key)
          requested = MessageTemplates.variant?(key, :whatsapp) ? MARKETING_CHANNELS : MARKETING_CHANNELS - ["whatsapp"]
          return requested if message_class.nil?

          decision = Messaging::ExternalCopyRouting.decide(
            user:, organization:, message_class:, requested_channels: requested,
            dedup_key: delivery_key(key)
          )
          decision.routed? ? decision.channels & requested : requested
        end

        def deliver_phone(key, locale:, **vars)
          text = render_if_present(key, :viber, locale:, **vars)
          template = whatsapp_template_for(key, **vars)
          return false if text.blank?

          options = { user:, organization:, topic: :platform_news, text:, template:, channels: MARKETING_CHANNELS }
          return false unless AccountNotifications.preview(**options)[:eligible]

          notification = AccountNotifications.enqueue!(**options, deduplication_key: delivery_key(key), enqueue_job: false, message_class: message_class_for(key))
          AccountNotifications.dispatch!(notification)
          state = notification.reload.status
          return notification.channels.include?("email") ? :email : true if %w(accepted delivered).include?(state)
          return :uncertain if %w(sending unknown pending).include?(state)

          false
        rescue StandardError => e
          Rails.logger.warn("[launch] phone delivery failed: #{e.class}")
          :uncertain
        end

        def render_if_present(key, channel, locale:, **vars)
          return unless MessageTemplates.variant?(key, channel)

          MessageTemplates.render(key, channel:, locale:, **vars)
        end

        def whatsapp_template_for(key, **vars)
          return unless Decidim::Bih::Config.infobip[:whatsapp_campaign_templates_enabled]
          return if Decidim::Bih::Config.infobip[:whatsapp_sender].blank?

          MessageTemplates.whatsapp_template(key, **vars)
        end

        # Most campaign messages have no dedicated email variant: email
        # tolerates the same full diacritics/length as Viber, so it reuses the
        # Viber-formatted text. Only P11 (the letter to MZ presidents) has its
        # own email variant.
        def deliver_email(key, locale:, **vars)
          return false unless Messaging::ProactiveEmail.allowed?(user, topic: :platform_news)

          channel = MessageTemplates.variant?(key, :email) ? :email : :viber
          return false unless MessageTemplates.variant?(key, channel)

          Decidim::Bih::Launch::InvitationMailer
            .with(user:, body: MessageTemplates.render(key, channel:, locale:, **vars), message_key: key, locale:)
            .campaign_message
            .deliver_later
          true
        end

        # The verified number, read fresh and kept in a local — NEVER logged,
        # never a job argument.
        def stored_phone
          Decidim::Bih::CitizenPhone.for(user)
        rescue StandardError
          nil
        end
      end
    end
  end
end
