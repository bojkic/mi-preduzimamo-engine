# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class InboundDeliveryEffectsTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @message = Decidim::Bih::Viber::InboundMessage.parse(
            "results" => [{
              "from" => "private-effects-sender",
              "messageId" => SecureRandom.uuid,
              "message" => { "type" => "TEXT", "text" => "Ulica needs repair" }
            }]
          )
          clear_enqueued_jobs
        end

        test "effect failure commits civic writes once and recovery skips the handler" do
          delivery = Decidim::Bih::Viber::InboundDelivery.accept!(
            organization: @organization,
            message: @message
          )
          handler_calls = 0
          handler = lambda do |message|
            handler_calls += 1
            Decidim::Bih::ReportIntake.new.call(
              organization: @organization,
              description: message.text,
              anonymous: true
            )
          end
          original_dispatch = Decidim::Bih::DurableEffects.method(:dispatch!)
          dispatch_calls = 0

          error = assert_raises(RuntimeError) do
            Decidim::Bih::DurableEffects.stub(:dispatch!, lambda { |effect|
              dispatch_calls += 1
              raise "queue unavailable" if dispatch_calls == 1

              original_dispatch.call(effect)
            }) do
              delivery.process!(handler:)
            end
          end
          assert_equal "queue unavailable", error.message
          assert_equal 1, handler_calls
          assert_equal 1, Decidim::Bih::Report.where(organization: @organization).count
          assert_equal "failed", delivery.reload.state
          assert_equal "effects", delivery.phase
          assert_nil delivery.encrypted_payload
          assert delivery.encrypted_effects.present?
          assert_equal 0, delivery.effects_cursor
          assert_equal 2, delivery.effects_count, "staff alert and report processing must both survive the queue outage"

          assert_equal :processed, delivery.recover_effects!
          assert_equal 1, handler_calls
          assert_equal 1, Decidim::Bih::Report.where(organization: @organization).count
          assert_equal(
            1,
            enqueued_jobs.count { |job| job.fetch(:job) == Decidim::Bih::ReportProcessingJob }
          )
          assert_equal(1, enqueued_jobs.count { |job| job.fetch(:job) == Decidim::Bih::ReportStaffAlertJob })
          assert_equal "processed", delivery.reload.state
          assert_equal "complete", delivery.phase
          assert_nil delivery.encrypted_effects
          assert_nil delivery.sender_digest
        end

        test "stale handler generation cannot rerun after a recovery claim reached effects" do
          delivery = accepted_delivery
          first_generation = delivery.send(:claim!)
          delivery.update!(state: "failed")
          second_generation = delivery.send(:claim!)
          delivery.update!(phase: "effects", encrypted_payload: nil)
          stale_handler_calls = 0
          parser = Class.new do
            def self.from_primitives(*) = :message
          end

          Decidim::Bih::Viber::InboundDelivery.stub(:decrypt, {}) do
            assert_raises(ActiveRecord::StaleObjectError) do
              delivery.send(
                :run_handler_phase!,
                handler: ->(*) { stale_handler_calls += 1 },
                message_class: parser,
                claim_generation: first_generation
              )
            end
          end

          assert_equal 0, stale_handler_calls
          assert_equal second_generation, delivery.reload.attempts
          assert_equal "effects", delivery.phase
        end

        test "stale cursor generation cannot skip a newer claim effect" do
          delivery = accepted_delivery
          effects = Array.new(3) do |index|
            {
              "type" => "cache_write",
              "key" => "test/effect/#{index}",
              "value" => index,
              "options" => ActiveJob::Arguments.serialize([{}]).first
            }
          end
          delivery.update!(
            state: "processing",
            phase: "effects",
            attempts: 2,
            encrypted_payload: nil,
            encrypted_effects: Decidim::Bih::Viber::InboundDelivery.encrypt_effects(effects),
            effects_cursor: 2,
            effects_count: 3
          )

          assert_raises(ActiveRecord::StaleObjectError) do
            delivery.send(:advance_effect_cursor!, 1, 1)
          end
          assert_equal 2, delivery.reload.effects_cursor
          assert_equal 2, delivery.attempts
        end

        test "fifth stale handler claim terminalizes and unblocks sender order" do
          earlier = accepted_delivery(message_id: "stale-five")
          later = accepted_delivery(message_id: "after-stale-five")
          earlier.update_columns( # rubocop:disable Rails/SkipsModelValidations
            state: "processing",
            phase: "handler",
            attempts: Decidim::Bih::Viber::InboundDelivery::MAX_ATTEMPTS,
            updated_at: (Decidim::Bih::Viber::InboundDelivery::STALE_PROCESSING_AFTER + 1.minute).ago
          )

          assert later.earlier_unfinished_for_sender?
          assert_not earlier.reload.recoverable_for_enqueue!
          assert_equal "discarded", earlier.reload.state
          assert_equal "complete", earlier.phase
          assert_equal "AttemptsExhausted", earlier.error_class
          assert_nil earlier.encrypted_payload
          assert_not later.reload.earlier_unfinished_for_sender?
        end

        private

        def accepted_delivery(message_id: SecureRandom.uuid)
          message = Decidim::Bih::Viber::InboundMessage.parse(
            "results" => [{
              "from" => "private-effects-sender",
              "messageId" => message_id,
              "message" => { "type" => "TEXT", "text" => "Private body" }
            }]
          )
          Decidim::Bih::Viber::InboundDelivery.accept!(organization: @organization, message:)
        end
      end
    end
  end
end
