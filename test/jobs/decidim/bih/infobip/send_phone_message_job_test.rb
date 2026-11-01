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
    SEND_PHONE_MESSAGE_JOB_TEST_DEFINED_APPLICATION_JOB = true
  end
end

require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/infobip/client"
require_relative "../../../../../app/services/decidim/bih/messaging/priority"
require_relative "../../../../../app/jobs/decidim/bih/infobip/send_phone_message_job"

module Decidim
  remove_const(:ApplicationJob) if const_defined?(:SEND_PHONE_MESSAGE_JOB_TEST_DEFINED_APPLICATION_JOB, false)
  remove_const(:SEND_PHONE_MESSAGE_JOB_TEST_DEFINED_APPLICATION_JOB) if const_defined?(:SEND_PHONE_MESSAGE_JOB_TEST_DEFINED_APPLICATION_JOB, false)

  module Bih
    module Infobip
      class SendPhoneMessageJobTest < Minitest::Test
        include ActiveSupport::Testing::TimeHelpers

        PHONE = "+38765123456"
        TEXT = "Kod: 123456; link: https://example.test/v/private-token"
        VIBER_TEXT = "Viber kod: 123456"
        TEMPLATE_TOKEN = "private-template-token"
        MESSENGER_ID = "private-messenger-recipient"

        SendPhoneMessageJob.include ActiveJob::EnqueueAfterTransactionCommit unless SendPhoneMessageJob < ActiveJob::EnqueueAfterTransactionCommit

        def setup
          @previous_adapter = SendPhoneMessageJob.queue_adapter
          @adapter = ActiveJob::QueueAdapters::TestAdapter.new(enqueue_after_transaction_commit: false)
          SendPhoneMessageJob.queue_adapter = @adapter
          # The unconfigured-client path records IntegrationHealth through the
          # process singleton. Give every test an in-memory store so no test
          # here can build the real RedisStore (one used to, with Rails.env
          # stubbed as production, and wrote to production db1).
          @previous_health = IntegrationHealth.instance_variable_get(:@instance)
          @health_store = IntegrationHealth::MemoryStore.new
          IntegrationHealth.instance = IntegrationHealth.new(store: @health_store)
        end

        def teardown
          SendPhoneMessageJob.queue_adapter = @previous_adapter
          IntegrationHealth.instance = @previous_health
        end

        def test_direct_enqueue_exposes_only_expiring_ciphertext_to_active_job
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            serialized = enqueue_phone
            envelope = decrypt(serialized)

            assert_ciphertext_only(serialized)
            assert_equal PHONE, envelope.fetch("to")
            assert_equal TEXT, envelope.fetch("text")
            assert_equal VIBER_TEXT, envelope.fetch("viber_text")
            assert_equal TEMPLATE_TOKEN, envelope.dig("viber_template", "parameters", "token")
            assert_equal MESSENGER_ID, envelope.dig("messenger", "to")
            assert_equal "123456", envelope.fetch("otp_code")
            assert_equal 23.hours.from_now, Time.iso8601(envelope.fetch("expires_at"))
          end

          assert_equal false, SendPhoneMessageJob.log_arguments
          assert_equal :always, SendPhoneMessageJob.enqueue_after_transaction_commit
          # Reserved authentication capacity (Phase 2 Task 2.7). Pinned to the
          # priority mapping rather than repeated as a bare literal, so the job
          # and Messaging::Priority cannot drift apart.
          assert_equal "authentication_critical", SendPhoneMessageJob.queue_name.to_s
          assert_equal Decidim::Bih::Messaging::Priority.queue_for_priority("authentication").to_s,
                       SendPhoneMessageJob.queue_name.to_s
        end

        def test_configured_scheduling_encrypts_and_clamps_caller_expiry_to_23_hours
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            serialized = enqueue_phone(wait: 5.minutes, expires_at: 2.days.from_now)

            assert_ciphertext_only(serialized)
            assert_in_delta 5.minutes.from_now.to_f, serialized.fetch(:at), 0.001
            assert_equal 23.hours.from_now, Time.iso8601(decrypt(serialized).fetch("expires_at"))
          end
        end

        def test_earlier_caller_deadline_is_preserved
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            deadline = 5.minutes.from_now

            assert_equal deadline, Time.iso8601(decrypt(enqueue_phone(expires_at: deadline)).fetch("expires_at"))
          end
        end

        def test_bulk_scheduling_serialize_defense_encrypts_arguments
          job = SendPhoneMessageJob.new(**phone_arguments(expires_at: 2.days.from_now))

          with_crypto { ActiveJob.perform_all_later(job) }

          assert_equal 1, @adapter.enqueued_jobs.size
          assert_ciphertext_only(@adapter.enqueued_jobs.first)
          assert_operator Time.iso8601(decrypt(@adapter.enqueued_jobs.first).fetch("expires_at")), :<=, 23.hours.from_now
        end

        def test_transaction_rollback_does_not_enqueue_authentication_secrets
          deferred = nil

          ActiveRecord.stub(:after_all_transactions_commit, ->(&block) { deferred = block }) do
            enqueue_phone
          end

          assert deferred, "expected adapter enqueue to be deferred until commit"
          assert_empty @adapter.enqueued_jobs
          # A rolled-back transaction discards the registered callback, so the
          # queue adapter never receives even the encrypted authentication job.
        end

        def test_invalid_expiry_is_rejected_without_adapter_serialization
          error = assert_raises(Error) { enqueue_phone(expires_at: "not-an-iso8601-time") }

          assert_equal "Infobip phone message expiry is invalid", error.message
          assert_empty @adapter.enqueued_jobs
          PRIVATE_VALUES.each { |value| refute_includes error.message, value }
        end

        def test_plain_keywords_remain_compatible_for_old_queue_drain
          sent = nil
          client = Object.new
          client.define_singleton_method(:configured?) { true }
          client.define_singleton_method(:send_phone_message) { |**attributes| sent = attributes }

          Client.stub(:new, client) do
            SendPhoneMessageJob.new.perform(**phone_arguments(expires_at: 5.minutes.from_now))
          end

          assert_equal PHONE, sent.fetch(:to)
          assert_equal TEXT, sent.fetch(:text)
          assert_equal VIBER_TEXT, sent.fetch(:viber_text)
          assert_equal TEMPLATE_TOKEN, sent.dig(:viber_template, :parameters, "token")
          assert_equal MESSENGER_ID, sent.dig(:messenger, :to)
          assert_equal "123456", sent.fetch(:otp_code)
          assert_operator sent.fetch(:expires_at), :<=, 5.minutes.from_now
        end

        def test_requested_channel_subset_is_encrypted_and_reaches_client
          sent = nil
          client = Object.new
          client.define_singleton_method(:configured?) { true }
          client.define_singleton_method(:send_phone_message) { |**attributes| sent = attributes }

          serialized = enqueue_phone(channels: [:sms])
          with_crypto do
            Client.stub(:new, client) do
              SendPhoneMessageJob.new.perform(encrypted_payload: encrypted_payload(serialized))
            end
          end

          assert_equal ["sms"], decrypt(serialized).fetch("channels")
          assert_equal [:sms], sent.fetch(:channels)
        end

        def test_expired_encrypted_message_is_dropped_without_constructing_client_or_logging_secrets
          output = StringIO.new
          constructed = false
          payload = encrypted_payload(enqueue_phone(expires_at: 1.minute.ago))

          Client.stub(:new, -> { constructed = true }) do
            Rails.stub(:logger, Logger.new(output)) do
              with_crypto { SendPhoneMessageJob.new.perform(encrypted_payload: payload) }
            end
          end

          refute constructed
          assert_includes output.string, "channel=phone stale authentication message dropped"
          assert_no_private_values(output.string)
        end

        def test_delivery_error_and_exhaustion_log_retain_only_safe_metadata
          client = Object.new
          client.define_singleton_method(:configured?) { true }
          client.define_singleton_method(:send_phone_message) do |**|
            raise Error.new(
              "provider body to=#{PHONE} text=#{TEXT}",
              http_status: 429,
              error_code: "RATE_LIMITED",
              error_group: "REJECTED"
            )
          end

          error = Client.stub(:new, client) do
            assert_raises(Error) { SendPhoneMessageJob.new.perform(**phone_arguments(expires_at: 5.minutes.from_now)) }
          end
          assert_equal "Infobip phone delivery failed", error.message
          assert_equal({ http_status: 429, error_code: "RATE_LIMITED", error_group: "REJECTED" }, error.metadata)
          assert_nil error.cause

          output = StringIO.new
          Rails.stub(:logger, Logger.new(output)) { SendPhoneMessageJob.log_exhausted_delivery(error) }

          assert_includes output.string, "channel=phone status=429 code=RATE_LIMITED group=REJECTED"
          assert_no_private_values(output.string)
        end

        def test_production_configuration_loss_raises_for_bounded_retry
          output = StringIO.new
          client = Object.new
          client.define_singleton_method(:configured?) { false }
          production = ActiveSupport::EnvironmentInquirer.new("production")

          error = Rails.stub(:env, production) do
            Client.stub(:new, client) do
              Rails.stub(:logger, Logger.new(output)) do
                assert_raises(Error) do
                  SendPhoneMessageJob.new.perform(**phone_arguments(expires_at: 5.minutes.from_now))
                end
              end
            end
          end

          assert_equal "Infobip phone delivery configuration is incomplete", error.message
          assert_no_private_values(output.string)
          recorded = @health_store.read(provider: "infobip", organization: "global")
          assert_equal "unconfigured", recorded[:last_error_code]
          assert_equal 1, recorded[:failure_count]
        end

        # Regression for the systemic hole: with the REAL default singleton
        # (lazy RedisStore) and Rails.env stubbed as production, the process is
        # still a latched test process, so an unset, db0 or db1 REDIS_URL is
        # refused before any Redis client is built. Redis.new is replaced by a
        # recorder: nothing here can reach a server.
        def test_production_env_stub_never_builds_a_default_redis_client
          production = ActiveSupport::EnvironmentInquirer.new("production")
          client = Object.new
          client.define_singleton_method(:configured?) { false }
          built = []
          [nil, "redis://127.0.0.1:6379/0", "redis://localhost:6379/1"].each do |url|
            IntegrationHealth.reset!
            with_redis_url(url) do
              Redis.stub(:new, ->(**options) { built << options.keys }) do
                Rails.stub(:env, production) do
                  Client.stub(:new, client) do
                    Rails.stub(:logger, Logger.new(StringIO.new)) do
                      assert_raises(Error) { SendPhoneMessageJob.new.perform(**phone_arguments(expires_at: 5.minutes.from_now)) }
                    end
                  end
                end
              end
            end
          end
          assert_empty built, "a Redis client was built under a production Rails.env stub"
        ensure
          IntegrationHealth.reset!
        end

        PRIVATE_VALUES = [PHONE, TEXT, VIBER_TEXT, TEMPLATE_TOKEN, MESSENGER_ID, "123456"].freeze

        private

        def with_redis_url(url)
          previous = ENV.fetch("REDIS_URL", nil)
          url ? ENV["REDIS_URL"] = url : ENV.delete("REDIS_URL")
          yield
        ensure
          previous ? ENV["REDIS_URL"] = previous : ENV.delete("REDIS_URL")
        end

        def enqueue_phone(wait: nil, expires_at: nil, channels: nil)
          with_crypto do
            target = wait ? SendPhoneMessageJob.set(wait:) : SendPhoneMessageJob
            target.perform_later(**phone_arguments(expires_at:, channels:))
          end
          @adapter.enqueued_jobs.last
        end

        def phone_arguments(expires_at: nil, channels: nil)
          {
            to: PHONE,
            text: TEXT,
            viber_text: VIBER_TEXT,
            viber_template: {
              template_id: "login-template",
              language: "bs",
              parameters: { token: TEMPLATE_TOKEN }
            },
            expires_at:,
            messenger: { to: MESSENGER_ID, session_active: true },
            channels:,
            otp_code: "123456"
          }
        end

        def encrypted_payload(serialized_job)
          serialized_job.fetch(:args).first.fetch("encrypted_payload")
        end

        def decrypt(serialized_job)
          with_crypto { SendPhoneMessageJob.send(:decrypt_envelope, encrypted_payload(serialized_job)) }
        end

        def assert_ciphertext_only(serialized_job)
          arguments = serialized_job.fetch(:args)
          application_keys = arguments.first.keys - ["_aj_ruby2_keywords"]
          serialized = JSON.generate(arguments)

          assert_equal ["encrypted_payload"], application_keys
          assert_equal ["encrypted_payload"], arguments.first.fetch("_aj_ruby2_keywords")
          assert_no_private_values(serialized)
        end

        def assert_no_private_values(value)
          PRIVATE_VALUES.each { |secret| refute_includes value, secret }
        end

        def with_crypto
          application = Struct.new(:secret_key_base).new("engine-phone-job-test-secret")
          Rails.stub(:application, application) { yield }
        end
      end
    end
  end
end
