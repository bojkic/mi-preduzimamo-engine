# frozen_string_literal: true

require "openssl"
require "securerandom"

module Decidim
  module Bih
    module ChannelConnections
      InvalidProof = Class.new(StandardError)
      PURPOSE = "account-channel-recipient-v1"
      SALT = "decidim-bih-account-channel-v1"
      CHANNELS = %w(whatsapp messenger instagram).freeze

      module_function

      def configured_sender(channel)
        return unless CHANNELS.include?(channel.to_s)
        return unless Infobip::Client.new.chat_channel_configured?(channel.to_s)

        Config.infobip[:"#{channel}_sender"].presence
      end

      def for_user(user:, organization:, channel:)
        recipient_for(user:, organization:, channel:, business_sender: configured_sender(channel))
      end

      def recipient_for(user:, organization:, channel:, business_sender:)
        return unless valid_user?(user, organization) && business_sender.present? && CHANNELS.include?(channel.to_s)

        ChannelConnection.active.find_by(decidim_user_id: user.id, decidim_organization_id: organization.id,
                                         channel: channel.to_s, business_sender: business_sender.to_s)
      end

      def begin!(user:, organization:, channel:)
        sender = configured_sender(channel)
        raise InvalidProof unless valid_user?(user, organization) && sender.present?

        token = SecureRandom.hex(16)
        challenge = nil
        user.with_lock do
          ChannelConnectionChallenge.where(decidim_user_id: user.id, decidim_organization_id: organization.id,
                                           channel: channel.to_s, consumed_at: nil).update_all(consumed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
          challenge = ChannelConnectionChallenge.create!(decidim_user_id: user.id, decidim_organization_id: organization.id,
                                                         channel: channel.to_s, business_sender: sender.to_s,
                                                         token_digest: digest(token), expires_at: 10.minutes.from_now)
        end
        ExpireChannelConnectionChallengeJob.set(wait_until: challenge.expires_at).perform_later(challenge.id)
        [challenge, "POVEZI #{token}"]
      end

      # Called only after the webhook's authentication and exact business recipient checks.
      # No account association exists until the same signed-in account confirms the
      # separate secret returned to this chat. A forwarded browser command is insufficient.
      def observe!(organization:, message:)
        channel = message.channel.to_s
        sender = configured_sender(channel)
        return unless sender.present? && sender.to_s == message.recipient.to_s

        event_time = original_event_time(message)
        return unless event_time

        address_digest = digest(message.sender.to_s)
        scope = { decidim_organization_id: organization.id, channel:, business_sender: sender.to_s }
        record_interaction(scope, address_digest, event_time)
        match = /\APOVEZI ([a-f0-9]{32})\z/i.match(message.text.to_s.strip)
        return unless match
        return I18n.t("decidim.bih.channel_connections.invalid") unless event_time > 10.minutes.ago

        challenge = ChannelConnectionChallenge.find_by(**scope, token_digest: digest(match[1].downcase))
        raise InvalidProof unless challenge

        confirmation = prove_chat!(challenge, event_time, message.sender.to_s)
        I18n.t("decidim.bih.channel_connections.chat_confirmation", code: confirmation)
      rescue InvalidProof
        I18n.t("decidim.bih.channel_connections.invalid")
      end

      def confirm!(user:, organization:, challenge_id:, confirmation:)
        raise InvalidProof unless valid_user?(user, organization)

        connection = nil
        invalid_confirmation = false
        user.with_lock do
          challenge = ChannelConnectionChallenge.lock.find_by(id: challenge_id, decidim_user_id: user.id,
                                                              decidim_organization_id: organization.id)
          validate_challenge!(challenge)
          unless accept_confirmation!(challenge, confirmation)
            invalid_confirmation = true
            next
          end

          recipient = decrypt(challenge.recipient_ciphertext)
          scope = { decidim_organization_id: organization.id, channel: challenge.channel, business_sender: challenge.business_sender }
          existing = ChannelConnection.active.find_by(**scope, recipient_digest: digest(recipient))
          raise InvalidProof if existing && existing.decidim_user_id != user.id

          ChannelConnection.active.where(**scope, decidim_user_id: user.id).update_all(revoked_at: Time.current, recipient_ciphertext: "") # rubocop:disable Rails/SkipsModelValidations
          connection = ChannelConnection.create!(**scope, decidim_user_id: user.id, recipient_digest: digest(recipient),
                                                          recipient_ciphertext: challenge.recipient_ciphertext,
                                                          verified_at: Time.current, last_inbound_at: challenge.last_inbound_at)
          challenge.update!(consumed_at: Time.current, recipient_ciphertext: nil, confirmation_digest: nil)
        end
        raise InvalidProof if invalid_confirmation

        connection
      rescue ActiveRecord::RecordNotUnique
        raise InvalidProof
      end

      def disconnect!(user:, organization:, channel:)
        raise InvalidProof unless valid_user?(user, organization) && CHANNELS.include?(channel.to_s)

        user.with_lock do
          ChannelConnection.active.where(decidim_organization_id: organization.id, decidim_user_id: user.id, channel: channel.to_s)
                           .update_all(revoked_at: Time.current, recipient_ciphertext: "") # rubocop:disable Rails/SkipsModelValidations
          ChannelConnectionChallenge.where(decidim_organization_id: organization.id, decidim_user_id: user.id, channel: channel.to_s, consumed_at: nil)
                                    .update_all(consumed_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        end
      end

      def original_event_time(message)
        event_time = message.respond_to?(:occurred_at) ? message.occurred_at : nil
        event_time if event_time && event_time <= Time.current
      end

      def prove_chat!(challenge, event_time, recipient)
        confirmation = SecureRandom.hex(6).upcase
        challenge.with_lock do
          raise InvalidProof if challenge.consumed_at || challenge.proved_at || challenge.expires_at <= Time.current || event_time < challenge.created_at - 1.second

          challenge.update!(proved_at: Time.current, confirmation_digest: digest(confirmation),
                            recipient_ciphertext: encrypt(recipient), last_inbound_at: event_time)
        end
        confirmation
      end

      def record_interaction(scope, address_digest, event_time)
        connection = ChannelConnection.active.find_by(**scope, recipient_digest: address_digest)
        connection&.with_lock do
          connection.update!(last_inbound_at: event_time) if connection.revoked_at.nil? && (connection.last_inbound_at.nil? || connection.last_inbound_at < event_time)
        end
      end

      def validate_challenge!(challenge)
        raise InvalidProof unless challenge && challenge.proved_at && !challenge.consumed_at && challenge.expires_at > Time.current
        raise InvalidProof unless configured_sender(challenge.channel).to_s == challenge.business_sender
      end

      def accept_confirmation!(challenge, confirmation)
        matches = challenge.confirmation_attempts < 5 && confirmation.to_s.bytesize <= 32 &&
                  ActiveSupport::SecurityUtils.secure_compare(challenge.confirmation_digest, digest(confirmation.to_s.strip.upcase))
        return true if matches

        attempts = challenge.confirmation_attempts + 1
        challenge.update!(confirmation_attempts: attempts, consumed_at: attempts >= 5 ? Time.current : nil)
        false
      end

      def encrypt(recipient)
        Infobip::EncryptedJobEnvelope.seal({ "recipient" => recipient }, purpose: PURPOSE, salt: SALT)
      end

      def decrypt(ciphertext)
        Infobip::EncryptedJobEnvelope.open(ciphertext, purpose: PURPOSE, salt: SALT).fetch("recipient")
      end

      def digest(value)
        OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{SALT}:#{value}")
      end

      def valid_user?(user, organization)
        user && organization && user.decidim_organization_id == organization.id && !user.deleted? && !user.blocked?
      end
    end
  end
end
