# frozen_string_literal: true

require "digest"
require "openssl"

module Decidim
  module Bih
    module Viber
      # Durable receipt for one provider webhook result. The database stores a
      # digest of the provider id and an encrypted envelope containing only the
      # primitives needed by the concierge. Successful processing immediately
      # removes the encrypted envelope; terminal metadata is PII-free.
      class InboundDelivery < Decidim::ApplicationRecord
        self.table_name = "decidim_bih_viber_inbound_deliveries"

        # "viber" is the dormant Viber Bot transport; "viber_bm" is Viber
        # Business Messages, the two-way channel MIlica actually runs on.
        CHANNELS = %w(viber viber_bm whatsapp messenger instagram).freeze
        STATES = %w(pending processing processed failed discarded).freeze
        PHASES = %w(handler effects complete).freeze
        SENDER_ORDER_BLOCKING_STATES = %w(pending processing failed).freeze
        RETENTION = 7.days
        MAX_ATTEMPTS = 5
        STALE_PROCESSING_AFTER = 15.minutes
        UnreadableEffects = Class.new(StandardError)

        belongs_to :organization,
                   class_name: "Decidim::Organization",
                   foreign_key: "decidim_organization_id"

        validates :provider_message_key, presence: true, length: { is: 64 }
        validates :channel, presence: true, inclusion: { in: CHANNELS }
        validates :state, presence: true, inclusion: { in: STATES }
        validates :phase, presence: true, inclusion: { in: PHASES }
        validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        validates :effects_cursor, :effects_count,
                  numericality: { only_integer: true, greater_than_or_equal_to: 0 }
        validates :effects_cursor, comparison: { less_than_or_equal_to: :effects_count }
        validates :received_at, :expires_at, presence: true

        scope :retryable, lambda {
          where(state: %w(pending failed))
            .where("phase = ? OR attempts < ?", "effects", MAX_ATTEMPTS)
        }
        scope :expired, -> { where(expires_at: ...Time.current) }
        scope :recovery_candidates, lambda {
          active = where("expires_at > ?", Time.current)
          effects_state = sanitize_sql_array(
            [
              "state IN (?) OR (state = ? AND updated_at < ?)",
              %w(pending failed),
              "processing",
              STALE_PROCESSING_AFTER.ago
            ]
          )
          handler_state = sanitize_sql_array(
            [
              "(state IN (?) AND attempts < ?) OR (state = ? AND updated_at < ?)",
              %w(pending failed),
              MAX_ATTEMPTS,
              "processing",
              STALE_PROCESSING_AFTER.ago
            ]
          )
          active.where(
            "(phase = ? AND (#{effects_state})) OR " \
            "(phase = ? AND (#{handler_state}))",
            "effects",
            "handler"
          )
        }

        class << self
          def accept!(organization:, message:)
            now = Time.current
            channel = message_channel(message)
            create_or_find_by!(
              organization:,
              channel:,
              provider_message_key: provider_message_key(message, channel:)
            ) do |delivery|
              delivery.sender_digest = identifier_digest(message.sender, channel:) if message.sender.present?
              delivery.encrypted_payload = encrypt(message.to_primitives)
              delivery.state = "pending"
              delivery.received_at = now
              delivery.expires_at = RETENTION.from_now
            end
          end

          def encrypt(attributes)
            encryptor.encrypt_and_sign(JSON.generate(attributes), purpose: "viber-inbound")
          end

          def decrypt(ciphertext)
            JSON.parse(encryptor.decrypt_and_verify(ciphertext, purpose: "viber-inbound"))
          end

          def encrypt_effects(effects)
            encryptor.encrypt_and_sign(JSON.generate(effects), purpose: "viber-inbound-effects")
          end

          def decrypt_effects(ciphertext)
            JSON.parse(encryptor.decrypt_and_verify(ciphertext, purpose: "viber-inbound-effects"))
          end

          private

          def message_channel(message)
            value = message.channel if message.respond_to?(:channel)
            value.to_s.presence || "viber"
          end

          def provider_message_key(message, channel:)
            raw = message.message_id.presence
            raise ArgumentError, "Inbound delivery requires a provider message id" unless raw

            identifier_digest(raw, channel:)
          end

          # Preserve the established Viber receipt keys while ensuring Meta
          # channel identifiers cannot become cross-platform correlation keys.
          def identifier_digest(value, channel:)
            return digest(value) if channel == "viber"

            OpenSSL::HMAC.hexdigest("SHA256", sender_digest_key, "#{channel}\0#{value}")
          end

          def digest(value)
            Digest::SHA256.hexdigest(value.to_s)
          end

          def sender_digest_key
            ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base.to_s)
                                       .generate_key("decidim-bih-inbound-sender-order", 32)
          end

          def encryptor
            generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base)
            key = generator.generate_key("decidim-bih-viber-inbound", 32)
            ActiveSupport::MessageEncryptor.new(key)
          end
        end

        def process!(handler:, message_class: nil)
          claim_generation = claim!
          return :skipped unless claim_generation

          run_handler_phase!(handler:, message_class:, claim_generation:) if phase == "handler"
          run_effects_phase!(claim_generation:)
          :processed
        rescue ActiveRecord::StaleObjectError
          # Another recovery claim fenced this worker. Its owner is now
          # responsible for the receipt; this stale execution must not retry or
          # overwrite the newer state.
          :skipped
        rescue StandardError => e
          fail_processing!(e, claim_generation:) if claim_generation
          raise
        end

        # Resume only the committed effects phase. Recovery jobs may call this
        # even when the original host handler method is temporarily unavailable;
        # it never decrypts the inbound message or invokes civic code.
        def recover_effects!
          return :skipped unless phase == "effects"

          scrub_result = scrub_expired_effects!
          return :discarded if scrub_result == :discarded

          claim_generation = claim!
          return :skipped unless claim_generation

          run_effects_phase!(claim_generation:)
          :processed
        rescue ActiveRecord::StaleObjectError
          :skipped
        rescue StandardError => e
          fail_processing!(e, claim_generation:) if claim_generation
          raise
        end

        def enqueueable?
          %w(pending failed).include?(state) &&
            (phase == "effects" || attempts < MAX_ATTEMPTS) &&
            expires_at > Time.current
        end

        def processing?
          state == "processing"
        end

        # True while an earlier, nonterminal receipt from the same external
        # sender can still be processed. External-chat workers use this before
        # claiming a receipt so concurrent jobs cannot race the short-lived
        # conversation cache. The comparison is deterministic even when a
        # provider batch gives multiple receipts the same timestamp.
        def earlier_unfinished_for_sender?
          return false if sender_digest.blank? || id.blank? || received_at.blank?

          self.class
              .where(
                decidim_organization_id:,
                channel:,
                sender_digest:,
                state: SENDER_ORDER_BLOCKING_STATES
              )
              .where("expires_at > ?", Time.current)
              .where("state = ? OR phase = ? OR attempts < ?", "processing", "effects", MAX_ATTEMPTS)
              .exists?(
                [
                  "received_at < ? OR (received_at = ? AND id < ?)",
                  received_at,
                  received_at,
                  id
                ]
              )
        end

        # The legacy table/model name remains the compatibility boundary for
        # Viber callers. New Infobip chat receipts use the generic normalizer.
        def message_class
          return Decidim::Bih::Viber::InboundMessage if channel == "viber"

          Decidim::Bih::Infobip::InboundMessage
        end

        def recoverable_for_enqueue!
          expected_claim_generation = nil
          with_lock do
            expected_claim_generation = attempts
            stale_processing = processing? && updated_at < STALE_PROCESSING_AFTER.ago
            scrub_expired_effects_under_lock! if phase == "effects"

            if stale_processing
              if phase == "handler" && attempts >= MAX_ATTEMPTS
                update!(
                  state: "discarded",
                  phase: "complete",
                  processed_at: Time.current,
                  encrypted_payload: nil,
                  encrypted_effects: nil,
                  next_effect_scrub_at: nil,
                  sender_digest: nil,
                  error_class: "AttemptsExhausted"
                )
                return false
              end

              update!(state: "failed", error_class: "StaleProcessing")
            end
            enqueueable?
          end
        rescue UnreadableEffects
          discard_unreadable_effects!(expected_claim_generation:)
          false
        end

        # Privacy maintenance can scrub short-lived effect payloads without
        # removing the seven-day provider-message dedupe receipt. Remaining
        # deadline-expired slots become payload-free no-op tombstones; cursor,
        # count and terminal receipt metadata are retained.
        def scrub_expired_effects!(now: Time.current)
          expected_claim_generation = nil
          with_lock do
            expected_claim_generation = attempts
            scrub_expired_effects_under_lock!(now:)
          end
        rescue UnreadableEffects
          discard_unreadable_effects!(expected_claim_generation:)
        end

        # Fail closed on a poison effects envelope without deleting the
        # provider-message dedupe receipt. The claim generation and a second
        # under-lock decode both fence this terminal transition: a newer owner
        # wins, and a concurrently repaired envelope is never discarded.
        def discard_unreadable_effects!(expected_claim_generation:)
          with_lock do
            next :stale unless phase == "effects" && attempts == expected_claim_generation

            begin
              verified_effects!
              :readable
            rescue UnreadableEffects
              update!(
                state: "discarded",
                phase: "complete",
                processed_at: Time.current,
                encrypted_payload: nil,
                encrypted_effects: nil,
                next_effect_scrub_at: nil,
                sender_digest: nil,
                error_class: "UnreadableEffects"
              )
              :discarded
            end
          end
        end

        private

        def run_handler_phase!(handler:, message_class:, claim_generation:)
          parser = message_class || self.message_class
          message = parser.from_primitives(self.class.decrypt(encrypted_payload))
          # Civic writes and the captured external-effect envelope commit
          # together. The receipt remains sender-order blocking in the effects
          # phase until every effect is durably cursor-advanced.
          self.class.transaction do
            lock!
            assert_active_claim!(claim_generation, expected_phase: "handler")

            capture = Decidim::Bih::DurableEffects.capture { handler.call(message) }
            effects = Decidim::Bih::DurableEffects.validate_effects!(capture.effects)
            update!(
              phase: "effects",
              encrypted_effects: encrypt_effects(effects),
              effects_cursor: 0,
              effects_count: effects.size,
              next_effect_scrub_at: earliest_effect_deadline(effects),
              encrypted_payload: nil,
              error_class: nil
            )
          end
        end

        def run_effects_phase!(claim_generation:)
          loop do
            current = next_effect(claim_generation)
            break unless current

            effect, expected_cursor = current

            # Dispatch precedes cursor advancement. If the worker dies in this
            # narrow interval, recovery may repeat this effect; it cannot lose
            # the effect or rerun the civic handler.
            Decidim::Bih::DurableEffects.dispatch!(effect)
            advance_effect_cursor!(expected_cursor, claim_generation)
          end

          finalize_effects!(claim_generation)
        end

        def next_effect(claim_generation)
          with_lock do
            assert_active_claim!(claim_generation)
            return if phase == "complete"
            raise ActiveRecord::RecordNotFound, "Inbound receipt is not in the effects phase" unless phase == "effects"

            effects = decrypted_effects
            raise ActiveRecord::RecordInvalid, self unless effects.size == effects_count

            effect = effects[effects_cursor]
            effect && [effect, effects_cursor]
          end
        end

        def advance_effect_cursor!(expected_cursor, claim_generation)
          with_lock do
            assert_active_claim!(claim_generation, expected_phase: "effects")
            raise ActiveRecord::StaleObjectError.new(self, "advance effects cursor") unless
              effects_cursor == expected_cursor

            effects = decrypted_effects
            raise ActiveRecord::RecordInvalid, self unless effects.size == effects_count
            raise ActiveRecord::StaleObjectError.new(self, "advance effects cursor") unless
              expected_cursor < effects_count

            # One locked database update both removes the just-consumed payload
            # and advances its cursor. A stale generation or cursor cannot
            # scrub/skip a slot owned by a newer recovery worker.
            effects[expected_cursor] = Decidim::Bih::DurableEffects.tombstone
            update!(
              encrypted_effects: encrypt_effects(effects),
              effects_cursor: expected_cursor + 1,
              next_effect_scrub_at: earliest_effect_deadline(effects, from: expected_cursor + 1)
            )
          end
        end

        def finalize_effects!(claim_generation)
          with_lock do
            assert_active_claim!(claim_generation)
            return if phase == "complete"
            raise ActiveRecord::RecordInvalid, self unless phase == "effects" && effects_cursor == effects_count

            complete!
          end
        end

        def decrypted_effects
          return [] if encrypted_effects.blank? && effects_count.zero?

          Decidim::Bih::DurableEffects.validate_effects!(self.class.decrypt_effects(encrypted_effects))
        end

        def encrypt_effects(effects)
          return nil if effects.empty?

          self.class.encrypt_effects(effects)
        end

        def scrub_expired_effects_under_lock!(now: Time.current)
          return 0 unless phase == "effects"

          effects = verified_effects!

          scrubbed = 0
          (effects_cursor...effects_count).each do |index|
            next unless Decidim::Bih::DurableEffects.expired?(effects[index], now:)

            effects[index] = Decidim::Bih::DurableEffects.tombstone
            scrubbed += 1
          end
          return 0 if scrubbed.zero?

          update!(
            encrypted_effects: encrypt_effects(effects),
            next_effect_scrub_at: earliest_effect_deadline(effects)
          )
          scrubbed
        end

        def verified_effects!
          effects = decrypted_effects
          return effects if effects.size == effects_count

          raise_unreadable_effects!
        rescue ActiveSupport::MessageEncryptor::InvalidMessage, JSON::ParserError,
               ArgumentError, KeyError, TypeError
          raise_unreadable_effects!
        end

        def raise_unreadable_effects!
          raise UnreadableEffects, "Inbound effect envelope is unreadable", cause: nil
        end

        def earliest_effect_deadline(effects, from: effects_cursor)
          effects.drop(from).filter_map do |effect|
            Decidim::Bih::DurableEffects.deadline_at(effect)
          end.min
        end

        def claim!
          with_lock do
            return false unless enqueueable?

            # Attempts is also the claim generation. Increment it for effects
            # recovery as well as handler work so a stale effects worker can
            # never advance/fail a newer recovery claim.
            update!(state: "processing", attempts: attempts + 1, error_class: nil)
            attempts
          end
        end

        def complete!
          update!(
            state: "processed",
            phase: "complete",
            processed_at: Time.current,
            encrypted_payload: nil,
            encrypted_effects: nil,
            next_effect_scrub_at: nil,
            sender_digest: nil,
            error_class: nil
          )
        end

        def fail_processing!(error, claim_generation:)
          with_lock do
            return unless processing? && attempts == claim_generation

            update!(
              state: "failed",
              error_class: error.class.name.to_s[0, 120]
            )
          end
        end

        def assert_active_claim!(claim_generation, expected_phase: nil)
          active = processing? && attempts == claim_generation
          active &&= phase == expected_phase if expected_phase
          return if active

          raise ActiveRecord::StaleObjectError.new(self, "process inbound receipt")
        end
      end
    end
  end
end
