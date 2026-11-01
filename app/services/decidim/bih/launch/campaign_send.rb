# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # Sends one campaign message to a list of citizens ONCE.
      #
      # Until now the campaign had no sender at all: MessageDispatcher was
      # called only from tests, and the runbook told the operator to loop over
      # citizens in a Rails console. That loop had no record of who had been
      # reached, so a run that died halfway and was restarted sent to everyone
      # again — on a paid channel, to the whole base. It also had no ceiling,
      # no dry run and no audit trail (review 2026-09-07, lane 6 H1).
      #
      # The ledger is one OperatorAuditEvent per (message_key, user): a re-run
      # skips everyone already reached. The ceiling refuses an oversized batch
      # BEFORE the first send rather than halfway through it. Dry run is the
      # default, so the operator sees the count before spending anything.
      #
      # Never SMS: MessageDispatcher has no SMS leg (owner decision
      # 2026-09-07), so nothing here is billed per segment.
      class CampaignSend
        CeilingExceeded = Class.new(StandardError)
        EVENT_TYPE = "launch_campaign_sent"
        DEFAULT_MAX_RECIPIENTS = 500
        BATCH_SIZE = 50

        def initialize(organization:, key:, recipients:, actor: nil, dry_run: true, # rubocop:disable Metrics/ParameterLists
                       max_recipients: DEFAULT_MAX_RECIPIENTS, locale: :sr, vars: {}, edition: nil)
          @organization = organization
          @key = key.to_s
          @recipients = recipients
          @actor = actor
          @dry_run = dry_run
          @max_recipients = max_recipients.to_i
          @locale = locale
          @vars = vars
          @edition = edition.to_s.presence
          raise ArgumentError, "invalid campaign edition" if @edition && !@edition.match?(/\A[a-zA-Z0-9_-]{1,80}\z/)
        end

        def call
          raise ArgumentError, "unknown message #{key}" unless MessageTemplates::KEYS.include?(key)

          builder.validate_state! if %w(p8 p9 p10).include?(key)
          raise ArgumentError, "weekly campaign edition required" if key == "p9" && edition.blank?
          all = recipients.to_a
          raise ArgumentError, "recipient organization mismatch" if all.any? { |u| u.decidim_organization_id != organization.id }

          pending = all.reject { |user| already_sent?(user) }
          skipped = all.size - pending.size
          if pending.size > max_recipients
            raise CeilingExceeded,
                  "#{pending.size} recipients exceed MAX_RECIPIENTS=#{max_recipients}"
          end
          pending.each { |user| validate_renderable!(user) }
          if dry_run
            # Render once before reporting "safe to send": a missing interpolation
            # variable is a typo in the operator's command, and finding it here
            # costs nothing while finding it at DRY_RUN=0 aborts the run partway
            # through a paid batch.
            return { sent: 0, skipped:, undeliverable: 0, dry_run: true, would_send: pending.size }
          end

          sent = 0
          undeliverable = 0
          pending.each_slice(BATCH_SIZE) do |batch|
            batch.each do |user|
              channel = MessageDispatcher.new(user, organization:).deliver(key, locale:, edition:, **vars_for(user))
              if channel == :undeliverable
                undeliverable += 1
              else
                record!(user, channel)
                sent += 1
              end
            end
          end
          { sent:, skipped:, undeliverable:, dry_run: false }
        end

        private

        attr_reader :organization, :key, :recipients, :actor, :dry_run, :max_recipients, :locale, :vars, :edition

        # Raises ArgumentError naming the missing variable, rather than
        # I18n::MissingInterpolationArgument from inside a half-finished batch.
        def validate_renderable!(user)
          return if user.blank?

          vars = vars_for(user)
          [:viber, :email, :email_subject].each do |channel|
            next unless MessageTemplates.variant?(key, channel)

            MessageTemplates.render(key, channel:, locale:, **vars)
          end
          MessageTemplates.whatsapp_template(key, **vars) if MessageTemplates.variant?(key, :whatsapp)
        rescue I18n::MissingInterpolationArgument => e
          raise ArgumentError, "#{key} needs #{e.key}: pass it to the task"
        end

        # The ledger is the audit row itself: one per citizen per message.
        def already_sent?(user)
          Decidim::Bih::OperatorAuditEvent
            .where(organization:, event_type: EVENT_TYPE)
            .exists?(["metadata ->> 'message_key' = ? AND metadata ->> 'user_id' = ? AND COALESCE(metadata ->> 'edition', '') = ?", key, user.id.to_s, edition.to_s])
        end

        # Ids and the channel only — never the number, never the body. The
        # model's own sanitiser would drop those keys anyway.
        def record!(user, channel)
          Decidim::Bih::OperatorAuditEvent.record!(
            organization:,
            actor:,
            event_type: EVENT_TYPE,
            metadata: { message_key: key, user_id: user.id, channel: channel.to_s, edition: }.compact
          )
        end

        def builder
          @builder ||= CampaignVariables.new(organization:, key:)
        end

        def vars_for(user)
          @prepared_vars ||= {}
          @prepared_vars[user.id] ||= begin
            supplied = vars.respond_to?(:call) ? vars.call(user) : vars
            # Race facts and winner date come from reviewed state, not arbitrary
            # CLI interpolation. P8 may carry an explicitly reviewed event count.
            if %w(p9 p10).include?(key) || (%w(p8).include?(key) && supplied.blank?)
              builder.call(user)
            else
              supplied.to_h.symbolize_keys
            end
          end
        end
      end
    end
  end
end
