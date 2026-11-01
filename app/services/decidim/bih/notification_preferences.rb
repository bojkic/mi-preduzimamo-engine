# frozen_string_literal: true

module Decidim
  module Bih
    # Compatibility names for legacy producers. Proactive permission now reads
    # four canonical topics; the old key map is retained for migration only.
    module NotificationPreferences
      TOPICS = %w(report_updates community_news platform_news neighborhood_info city_service_alerts).freeze
      CHANNELS = %w(viber whatsapp messenger instagram).freeze
      LEGACY_LOCAL_ALERTS_KEY = "komsiluk_board"

      TOPIC_CHANNEL_KEYS = {
        komsiluk_urgent: {
          bell: "mi_komsiluk_urgent_bell"
        },
        city_service_alerts: {
          viber: "mi_city_service_alerts_viber"
        }
      }.merge(TOPICS.to_h { |topic| [topic.to_sym, CHANNELS.to_h { |channel| [channel.to_sym, "mi_#{topic}_#{channel}"] }] }).freeze

      class << self
        def key(topic:, channel:)
          TOPIC_CHANNEL_KEYS.fetch(topic.to_sym).fetch(channel.to_sym)
        end

        def boolean_keys
          @boolean_keys ||= (
            [LEGACY_LOCAL_ALERTS_KEY] +
            TOPIC_CHANNEL_KEYS.values.flat_map(&:values)
          ).uniq.freeze
        end

        # Compatibility entry point for old producers. A topic is independent
        # of its transport. Bell rows remain available even for disabled topics.
        def enabled?(user, topic:, channel:, **_legacy_options)
          return true if channel.to_s == "bell"

          TopicPreferences.enabled?(user, topic:)
        end

        def explicit?(user, topic:, channel:)
          return false if channel.to_s == "bell"

          Messaging::Preference.exists?(user:, organization: user.organization, topic: TopicPreferences.canonical_topic(topic))
        end

        def permitted?(user, topic:, channel:)
          enabled?(user, topic:, channel:)
        end

        def set!(user, topic:, channel:, enabled:, source: "account")
          raise ArgumentError, "provider refusals belong to transport suppression" if source == "provider_opt_out"
          return if channel.to_s == "bell"

          TopicPreferences.set!(user, topic:, enabled:, source:)
        end

        # Only a business-sender-validated webhook can record a STOP. The
        # refusal applies to its destination/channel, including future accounts
        # at that destination, without disabling topics on other transports.
        def opt_out_sender!(organization:, channel:, sender:, business_sender:)
          channel = channel.to_s
          return false unless CHANNELS.include?(channel)

          sender_key = { "viber" => :viber_bm_sender, "whatsapp" => :whatsapp_sender,
                         "messenger" => :messenger_sender, "instagram" => :instagram_sender }.fetch(channel)
          return false unless business_sender.present? && Config.infobip[sender_key].to_s == business_sender.to_s

          users = sender_users(organization:, channel:, sender:, business_sender:)
          suppress_sender!(organization:, channel:, sender:, user: users.one? ? users.first : nil)

          return false unless users.one?

          # A STOP belongs to this destination/channel, never to the topic on
          # other channels. The durable suppression above is the write.
          true
        end

        private

        # Do not acknowledge a STOP whose durable suppression could not be
        # recorded. Retrying the webhook is safe because ingest is idempotent.
        #
        # The pure unit suite loads this facade without Active Record.
        def suppress_sender!(organization:, channel:, sender:, user:)
          return unless defined?(Messaging::TransportSuppression)

          Messaging::TransportSuppression.ingest!(
            organization:, provider: "infobip", channel:,
            destination: destination_for(channel:, sender:),
            reason: "provider_opt_out", source: "provider_webhook", user:
          )
        end

        # A phone is a phone and an opaque chat identity is not one, however
        # many digits it has. Parsing a Messenger id as a phone would let it
        # suppress a real handset.
        def destination_for(channel:, sender:)
          kind = %w(viber whatsapp).include?(channel) && sender.to_s.match?(/\A\+?[1-9][0-9]{6,14}\z/) ? :phone : :channel_identity
          { kind:, value: sender }
        end

        def sender_users(organization:, channel:, sender:, business_sender:)
          connection = ChannelConnection.active.find_by(decidim_organization_id: organization.id, channel:,
                                                        business_sender:, recipient_digest: ChannelConnections.digest(sender))
          users = [connection&.user].compact
          if %w(viber whatsapp).include?(channel) && sender.to_s.match?(/\A\+?[1-9][0-9]{6,14}\z/)
            digits = sender.to_s.delete_prefix("+")
            # A verified stored local representation and its international form
            # address the same proven phone; opaque IDs never enter this lookup.
            candidates = [digits]
            country = Config.default_country_code.to_s
            candidates << "0#{digits.delete_prefix(country)}" if digits.start_with?(country)
            CitizenPhoneRecord.where(organization:).where("regexp_replace(phone, '[^0-9]', '', 'g') IN (?)", candidates).each do |record|
              phone = VerifiedPhone.delivery_phone_for(user: record.user, organization:)
              users << record.user if phone.to_s.delete_prefix("+") == digits
            end
          end
          users.uniq(&:id)
        end
      end
    end
  end
end
