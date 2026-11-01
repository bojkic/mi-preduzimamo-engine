# frozen_string_literal: true

require "test_helper"
require "json"
require "logger"
require "stringio"
require "active_job"
require "active_job/queue_adapters/test_adapter"
require "active_support/testing/time_helpers"
require "decidim/bih"

module Decidim
  unless const_defined?(:ApplicationJob, false)
    class ApplicationJob < ActiveJob::Base; end
    SEND_VIBER_REPLY_JOBS_TEST_DEFINED_APPLICATION_JOB = true
  end
end

require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/infobip/client"
require_relative "../../../../../app/services/decidim/bih/concierge/stickers"
require_relative "../../../../../app/jobs/decidim/bih/infobip/send_viber_image_job"
require_relative "../../../../../app/jobs/decidim/bih/infobip/send_viber_text_job"

module Decidim
  remove_const(:ApplicationJob) if const_defined?(:SEND_VIBER_REPLY_JOBS_TEST_DEFINED_APPLICATION_JOB, false)
  remove_const(:SEND_VIBER_REPLY_JOBS_TEST_DEFINED_APPLICATION_JOB) if const_defined?(:SEND_VIBER_REPLY_JOBS_TEST_DEFINED_APPLICATION_JOB, false)

  module Bih
    module Infobip
      class SendViberReplyJobsTest < Minitest::Test
        include ActiveSupport::Testing::TimeHelpers

        def setup
          @previous_text_adapter = SendViberTextJob.queue_adapter
          @previous_image_adapter = SendViberImageJob.queue_adapter
          @adapter = ActiveJob::QueueAdapters::TestAdapter.new(enqueue_after_transaction_commit: false)
          SendViberTextJob.queue_adapter = @adapter
          SendViberImageJob.queue_adapter = @adapter
          # The Viber Bot is switched off for this deployment (Business Messages
          # only). This file covers the dormant transport so it still works if
          # revived, so it opts the switch on explicitly.
          @previous_bot_enabled = ENV.fetch("DECIDIM_BIH_VIBER_BOT_ENABLED", nil)
          ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = "true"
          Decidim::Bih::Config.reset!
        end

        def teardown
          SendViberTextJob.queue_adapter = @previous_text_adapter
          SendViberImageJob.queue_adapter = @previous_image_adapter
          if @previous_bot_enabled.nil?
            ENV.delete("DECIDIM_BIH_VIBER_BOT_ENABLED")
          else
            ENV["DECIDIM_BIH_VIBER_BOT_ENABLED"] = @previous_bot_enabled
          end
          Decidim::Bih::Config.reset!
        end

        def test_text_enqueue_exposes_only_expiring_ciphertext_to_active_job
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            serialized = enqueue_text
            ciphertext = encrypted_payload(serialized)
            envelope = with_crypto { SendViberTextJob.send(:decrypt_envelope, ciphertext) }

            assert_ciphertext_only(serialized, "private-viber-recipient", "Private Viber reply", "heart")
            assert_equal "private-viber-recipient", envelope.fetch("to")
            assert_equal "Private Viber reply", envelope.fetch("text")
            assert_equal "heart", envelope.fetch("sticker")
            assert_equal 23.hours.from_now, Time.iso8601(envelope.fetch("expires_at"))
          end

          assert_equal false, SendViberTextJob.log_arguments
          assert_equal "integrations", SendViberTextJob.queue_name.to_s
        end

        def test_configured_scheduling_encrypts_both_jobs_and_clamps_expiry_to_23_hours
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            text = enqueue_text(wait: 5.minutes, expires_at: 2.days.from_now)
            image = enqueue_image(wait: 5.minutes, expires_at: 2.days.from_now)
            text_envelope = decrypt_text(text)
            image_envelope = decrypt_image(image)

            assert_ciphertext_only(text, "private-viber-recipient", "Private Viber reply", "heart")
            assert_ciphertext_only(image, "private-viber-recipient", "heart")
            assert_in_delta 5.minutes.from_now.to_f, text.fetch(:at), 0.001
            assert_in_delta 5.minutes.from_now.to_f, image.fetch(:at), 0.001
            assert_equal 23.hours.from_now, Time.iso8601(text_envelope.fetch("expires_at"))
            assert_equal 23.hours.from_now, Time.iso8601(image_envelope.fetch("expires_at"))
          end

          assert_equal false, SendViberImageJob.log_arguments
          assert_equal "integrations", SendViberImageJob.queue_name.to_s
        end

        def test_invalid_expiry_is_rejected_without_serializing_private_arguments
          error = assert_raises(Error) { enqueue_text(expires_at: "not-an-iso8601-time") }

          assert_equal "Viber reply expiry is invalid", error.message
          assert_empty @adapter.enqueued_jobs
          refute_includes error.message, "private-viber-recipient"
          refute_includes error.message, "Private Viber reply"
        end

        def test_bulk_scheduling_serialize_defense_encrypts_both_jobs
          text_job = SendViberTextJob.new(
            organization_id: 7,
            to: "private-viber-recipient",
            text: "Private Viber reply",
            sticker: "heart"
          )
          image_job = SendViberImageJob.new(
            organization_id: 7,
            to: "private-viber-recipient",
            sticker: "heart"
          )

          with_crypto { ActiveJob.perform_all_later(text_job, image_job) }

          assert_equal 2, @adapter.enqueued_jobs.size
          assert_ciphertext_only(@adapter.enqueued_jobs.first, "private-viber-recipient", "Private Viber reply", "heart")
          assert_ciphertext_only(@adapter.enqueued_jobs.last, "private-viber-recipient", "heart")
        end

        def test_outbound_viber_text_is_capped_at_official_4000_character_limit
          long_text = "č" * (SendViberTextJob::MAX_REPLY_TEXT_LENGTH + 5)
          serialized = nil

          with_crypto do
            SendViberTextJob.perform_later(
              organization_id: 7,
              to: "private-viber-recipient",
              text: long_text
            )
            serialized = @adapter.enqueued_jobs.last
          end

          envelope = decrypt_text(serialized)
          assert_equal SendViberTextJob::MAX_REPLY_TEXT_LENGTH, envelope.fetch("text").length
          assert_equal "č" * SendViberTextJob::MAX_REPLY_TEXT_LENGTH, envelope.fetch("text")
          refute_includes JSON.generate(serialized.fetch(:args)), long_text
        end

        def test_expired_text_reply_is_dropped_before_client_construction_without_content_in_log
          output = StringIO.new
          constructed = false
          encrypted_payload = encrypted_payload(enqueue_text(expires_at: 1.minute.ago))

          Client.stub(:new, -> { constructed = true }) do
            Rails.stub(:logger, Logger.new(output)) do
              with_crypto { SendViberTextJob.new.perform(encrypted_payload:) }
            end
          end

          refute constructed
          assert_includes output.string, "channel=viber expired session reply dropped"
          refute_includes output.string, "private-viber-recipient"
          refute_includes output.string, "Private Viber reply"
        end

        def test_text_delivery_rethrows_only_safe_diagnostics
          client = Object.new
          client.define_singleton_method(:viber_bot_configured?) { true }
          client.define_singleton_method(:viber_bot_active?) { true }
          client.define_singleton_method(:send_viber_bot) do |**|
            raise Error.new(
              "provider body recipient=private-viber-recipient text=Private Viber reply",
              http_status: 429,
              error_code: "RATE_LIMITED",
              error_group: "REJECTED"
            )
          end

          error = Client.stub(:new, client) do
            assert_raises(Error) do
              SendViberTextJob.new.perform(
                organization_id: 7,
                to: "private-viber-recipient",
                text: "Private Viber reply"
              )
            end
          end

          assert_equal "Infobip Viber Bot delivery failed", error.message
          assert_equal({ http_status: 429, error_code: "RATE_LIMITED", error_group: "REJECTED" }, error.metadata)
          assert_nil error.cause
          refute_includes error.message, "private-viber-recipient"
          refute_includes error.message, "Private Viber reply"
        end

        def test_sticker_enqueue_failure_does_not_retry_an_already_sent_text
          output = StringIO.new
          sent = 0
          client = Object.new
          client.define_singleton_method(:viber_bot_configured?) { true }
          client.define_singleton_method(:viber_bot_active?) { true }
          client.define_singleton_method(:send_viber_bot) { |**| sent += 1 }

          Client.stub(:new, client) do
            SendViberImageJob.stub(:perform_later, ->(**) { raise "queue unavailable private-content" }) do
              Rails.stub(:logger, Logger.new(output)) do
                SendViberTextJob.new.perform(
                  organization_id: 7,
                  to: "private-viber-recipient",
                  text: "Private Viber reply",
                  sticker: "celebrate"
                )
              end
            end
          end

          assert_equal 1, sent
          assert_includes output.string, "sticker enqueue failed class=RuntimeError"
          refute_includes output.string, "private-content"
          refute_includes output.string, "private-viber-recipient"
        end

        def test_persona_gesture_uses_static_provider_asset
          sent = nil
          organization = Struct.new(:host).new("mi.example.test")
          client = Object.new
          client.define_singleton_method(:viber_bot_configured?) { true }
          client.define_singleton_method(:viber_bot_active?) { true }
          client.define_singleton_method(:send_viber_bot_image) { |**attributes| sent = attributes }

          job = SendViberImageJob.new
          job.stub(:organization_for, organization) do
            Client.stub(:new, client) do
              job.perform(
                organization_id: 7,
                to: "private-viber-recipient",
                sticker: "milica_wave"
              )
            end
          end

          assert_equal "private-viber-recipient", sent.fetch(:to)
          assert_equal "https://mi.example.test/mi/milica/wave.jpg", sent.fetch(:image_url)
        end

        def test_production_configuration_loss_raises_for_bounded_retry
          client = Object.new
          client.define_singleton_method(:viber_bot_configured?) { false }
          client.define_singleton_method(:viber_bot_active?) { false }
          production = ActiveSupport::EnvironmentInquirer.new("production")

          error = Rails.stub(:env, production) do
            Client.stub(:new, client) do
              assert_raises(Error) do
                SendViberTextJob.new.perform(
                  organization_id: 7,
                  to: "private-viber-recipient",
                  text: "Private Viber reply"
                )
              end
            end
          end

          assert_equal "Infobip Viber Bot configuration is incomplete", error.message
          refute_includes error.message, "private-viber-recipient"
          refute_includes error.message, "Private Viber reply"
        end

        def test_retry_exhaustion_log_contains_only_safe_viber_diagnostics
          output = StringIO.new
          unsafe = "provider body recipient=private-viber-recipient text=Private Viber reply"
          error = Error.new(unsafe, http_status: 503, error_code: "TEMPORARY", error_group: "REJECTED")

          Rails.stub(:logger, Logger.new(output)) do
            SendViberTextJob.log_exhausted_delivery(error)
          end

          assert_includes output.string, "channel=viber status=503 code=TEMPORARY group=REJECTED"
          refute_includes output.string, "private-viber-recipient"
          refute_includes output.string, "Private Viber reply"
        end

        private

        def enqueue_text(wait: nil, expires_at: nil)
          with_crypto do
            target = wait ? SendViberTextJob.set(wait:) : SendViberTextJob
            target.perform_later(
              organization_id: 7,
              to: "private-viber-recipient",
              text: "Private Viber reply",
              sticker: "heart",
              expires_at:
            )
          end
          @adapter.enqueued_jobs.last
        end

        def enqueue_image(wait: nil, expires_at: nil)
          with_crypto do
            target = wait ? SendViberImageJob.set(wait:) : SendViberImageJob
            target.perform_later(
              organization_id: 7,
              to: "private-viber-recipient",
              sticker: "heart",
              expires_at:
            )
          end
          @adapter.enqueued_jobs.last
        end

        def encrypted_payload(serialized_job)
          serialized_job.fetch(:args).first.fetch("encrypted_payload")
        end

        def decrypt_text(serialized_job)
          with_crypto { SendViberTextJob.send(:decrypt_envelope, encrypted_payload(serialized_job)) }
        end

        def decrypt_image(serialized_job)
          with_crypto { SendViberImageJob.send(:decrypt_envelope, encrypted_payload(serialized_job)) }
        end

        def assert_ciphertext_only(serialized_job, *plaintext_values)
          arguments = serialized_job.fetch(:args)
          application_keys = arguments.first.keys - ["_aj_ruby2_keywords"]
          serialized = JSON.generate(arguments)

          assert_equal ["encrypted_payload"], application_keys
          assert_equal ["encrypted_payload"], arguments.first.fetch("_aj_ruby2_keywords")
          plaintext_values.each { |value| refute_includes serialized, value }
        end

        def with_crypto
          application = Struct.new(:secret_key_base).new("engine-viber-job-test-secret")
          Rails.stub(:application, application) { yield }
        end
      end
    end
  end
end
