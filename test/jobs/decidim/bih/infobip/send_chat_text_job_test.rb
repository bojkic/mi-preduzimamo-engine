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
    SEND_CHAT_TEXT_JOB_TEST_DEFINED_APPLICATION_JOB = true
  end
end

require_relative "../../../../../app/services/decidim/bih/infobip/error"
require_relative "../../../../../app/services/decidim/bih/infobip/client"
require_relative "../../../../../app/services/decidim/bih/concierge/stickers"
require_relative "../../../../../app/jobs/decidim/bih/infobip/send_chat_text_job"

module Decidim
  remove_const(:ApplicationJob) if const_defined?(:SEND_CHAT_TEXT_JOB_TEST_DEFINED_APPLICATION_JOB, false)
  remove_const(:SEND_CHAT_TEXT_JOB_TEST_DEFINED_APPLICATION_JOB) if const_defined?(:SEND_CHAT_TEXT_JOB_TEST_DEFINED_APPLICATION_JOB, false)

  module Bih
    module Infobip
      class SendChatTextJobTest < Minitest::Test
        include ActiveSupport::Testing::TimeHelpers

        ENV_KEYS = %w(
          INFOBIP_BASE_URL INFOBIP_API_KEY INFOBIP_CHAT_CHANNELS INFOBIP_WHATSAPP_SENDER
          INFOBIP_MESSENGER_SENDER
        ).freeze

        def setup
          @original_env = ENV_KEYS.index_with { |key| ENV.fetch(key, nil) }
          ENV_KEYS.each { |key| ENV.delete(key) }
          Config.reset!
          @previous_adapter = SendChatTextJob.queue_adapter
          @adapter = ActiveJob::QueueAdapters::TestAdapter.new(enqueue_after_transaction_commit: false)
          SendChatTextJob.queue_adapter = @adapter
        end

        def teardown
          SendChatTextJob.queue_adapter = @previous_adapter
          @original_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Config.reset!
        end

        def test_enqueue_exposes_only_expiring_ciphertext_to_active_job
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            serialized = enqueue_chat
            ciphertext = encrypted_payload(serialized)
            envelope = decrypt(serialized)

            assert_ciphertext_only(serialized)
            assert_equal "whatsapp", envelope.fetch("channel")
            assert_equal "private-recipient", envelope.fetch("to")
            assert_equal "Private citizen reply", envelope.fetch("text")
            assert_equal "private-sender", envelope.fetch("sender")
            assert_equal false, envelope.fetch("request_phone")
            assert_equal 23.hours.from_now, Time.iso8601(envelope.fetch("expires_at"))
            refute_includes ciphertext, "private-recipient"
          end

          assert_equal false, SendChatTextJob.log_arguments
          assert_equal "integrations", SendChatTextJob.queue_name.to_s
        end

        def test_media_metadata_is_inside_ciphertext_and_dispatches_after_text
          serialized = enqueue_chat(organization_id: 7, media_id: "milica_wave")
          envelope = decrypt(serialized)

          assert_ciphertext_only(serialized)
          assert_equal 7, envelope.fetch("organization_id")
          assert_equal "milica_wave", envelope.fetch("media_id")

          calls = []
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |channel| channel == "whatsapp" }
          client.define_singleton_method(:send_chat_text) { |**| calls << :text }
          client.define_singleton_method(:send_chat_image) do |**attributes|
            calls << [:image, attributes]
          end
          organization = Struct.new(:host).new("mi.example.test")

          job = SendChatTextJob.new
          Client.stub(:new, client) do
            job.stub(:organization_for, organization) do
              with_crypto { job.perform(encrypted_payload: encrypted_payload(serialized)) }
            end
          end

          assert_equal :text, calls.first
          assert_equal :image, calls.last.first
          assert_equal "https://mi.example.test/mi/milica/wave.jpg", calls.last.last.fetch(:image_url)
          assert_equal "private-recipient", calls.last.last.fetch(:to)
        end

        def test_media_failure_does_not_retry_already_accepted_text_or_log_content
          serialized = enqueue_chat(organization_id: 7, media_id: "milica_wave")
          output = StringIO.new
          sent = 0
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |_channel| true }
          client.define_singleton_method(:send_chat_text) { |**| sent += 1 }
          client.define_singleton_method(:send_chat_image) do |**|
            raise Error.new("private provider body", http_status: 429, error_code: "RATE_LIMITED", error_group: "REJECTED")
          end
          organization = Struct.new(:host).new("mi.example.test")

          job = SendChatTextJob.new
          Client.stub(:new, client) do
            job.stub(:organization_for, organization) do
              Rails.stub(:logger, Logger.new(output)) do
                with_crypto { job.perform(encrypted_payload: encrypted_payload(serialized)) }
              end
            end
          end

          assert_equal 1, sent
          assert_includes output.string, "media_failed status=429 code=RATE_LIMITED group=REJECTED"
          refute_includes output.string, "private-recipient"
          refute_includes output.string, "Private citizen reply"
          refute_includes output.string, "private provider body"
        end

        def test_configured_scheduling_encrypts_and_clamps_expiry_to_23_hours
          travel_to Time.utc(2026, 8, 12, 12, 0, 0) do
            serialized = enqueue_chat(wait: 5.minutes, expires_at: 2.days.from_now)
            envelope = decrypt(serialized)

            assert_ciphertext_only(serialized)
            assert_in_delta 5.minutes.from_now.to_f, serialized.fetch(:at), 0.001
            assert_equal 23.hours.from_now, Time.iso8601(envelope.fetch("expires_at"))
          end
        end

        def test_bulk_scheduling_serialize_defense_encrypts_arguments
          job = SendChatTextJob.new(
            channel: "whatsapp",
            to: "private-recipient",
            text: "Private citizen reply",
            sender: "private-sender",
            expires_at: 2.days.from_now
          )

          with_crypto { ActiveJob.perform_all_later(job) }

          assert_equal 1, @adapter.enqueued_jobs.size
          assert_ciphertext_only(@adapter.enqueued_jobs.first)
          assert_operator Time.iso8601(decrypt(@adapter.enqueued_jobs.first).fetch("expires_at")), :<=, 23.hours.from_now
        end

        def test_transaction_rollback_does_not_enqueue_a_reply
          assert_equal :always, SendChatTextJob.enqueue_after_transaction_commit
          SendChatTextJob.include ActiveJob::EnqueueAfterTransactionCommit unless SendChatTextJob < ActiveJob::EnqueueAfterTransactionCommit
          deferred = nil

          ActiveRecord.stub(:after_all_transactions_commit, ->(&block) { deferred = block }) do
            enqueue_chat
          end

          assert deferred, "expected queue adapter call to be deferred until commit"
          assert_empty @adapter.enqueued_jobs
          # Dropping the registered callback models a transaction rollback: the
          # adapter never sees the already-sealed reply job.
        end

        def test_invalid_expiry_is_rejected_without_serializing_private_arguments
          error = assert_raises(Error) { enqueue_chat(expires_at: "not-an-iso8601-time") }

          assert_equal "Infobip chat reply expiry is invalid", error.message
          assert_empty @adapter.enqueued_jobs
          refute_includes error.message, "private-recipient"
          refute_includes error.message, "Private citizen reply"
        end

        def test_expired_reply_is_dropped_before_client_construction_and_log_has_no_content
          output = StringIO.new
          constructed = false
          payload = encrypted_payload(enqueue_chat(expires_at: 1.minute.ago))

          Client.stub(:new, -> { constructed = true }) do
            Rails.stub(:logger, Logger.new(output)) do
              with_crypto { SendChatTextJob.new.perform(encrypted_payload: payload) }
            end
          end

          refute constructed
          assert_includes output.string, "expired session reply dropped"
          refute_includes output.string, "private-recipient"
          refute_includes output.string, "Private citizen reply"
        end

        def test_enabled_channel_with_incomplete_production_config_raises_for_retry
          ENV["INFOBIP_BASE_URL"] = "https://infobip.example.test"
          ENV["INFOBIP_API_KEY"] = "test-api-key"
          ENV["INFOBIP_CHAT_CHANNELS"] = "whatsapp"
          Config.reset!
          production = ActiveSupport::EnvironmentInquirer.new("production")
          payload = encrypted_payload(enqueue_chat(expires_at: 1.hour.from_now))

          error = Rails.stub(:env, production) do
            assert_raises(Error) do
              with_crypto { SendChatTextJob.new.perform(encrypted_payload: payload) }
            end
          end

          assert_equal "whatsapp chat configuration is incomplete", error.message
          refute_includes error.message, "private-recipient"
        end

        def test_plain_keywords_remain_compatible_for_direct_and_old_queue_execution
          sent = nil
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |channel| channel == "whatsapp" }
          client.define_singleton_method(:send_chat_text) { |**attributes| sent = attributes }

          Client.stub(:new, client) do
            SendChatTextJob.new.perform(
              channel: "whatsapp",
              to: "private-recipient",
              text: "Private citizen reply",
              sender: "private-sender"
            )
          end

          assert_equal(
            {
              channel: "whatsapp",
              to: "private-recipient",
              text: "Private citizen reply",
              sender: "private-sender",
              request_phone: false
            },
            sent
          )
        end

        def test_encrypted_old_queue_without_phone_flag_defaults_false
          envelope = SendChatTextJob.send(
            :build_envelope,
            channel: "messenger",
            to: "private-recipient",
            text: "Private citizen reply",
            sender: "private-sender",
            expires_at: 10.minutes.from_now
          )
          envelope.delete("request_phone")
          sent = nil
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |_channel| true }
          client.define_singleton_method(:send_chat_text) { |**attributes| sent = attributes }

          Client.stub(:new, client) do
            with_crypto do
              payload = SendChatTextJob.send(:encrypt_envelope, envelope)
              SendChatTextJob.new.perform(encrypted_payload: payload)
            end
          end

          assert_equal false, sent.fetch(:request_phone)
        end

        def test_messenger_phone_request_flag_is_encrypted_and_dispatched
          serialized = enqueue_chat(channel: "messenger", request_phone: true, expires_at: 10.minutes.from_now)
          envelope = decrypt(serialized)
          sent = nil
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |channel| channel == "messenger" }
          client.define_singleton_method(:send_chat_text) { |**attributes| sent = attributes }

          assert_ciphertext_only(serialized)
          assert_equal true, envelope.fetch("request_phone")
          assert_equal "messenger", envelope.fetch("channel")

          Client.stub(:new, client) do
            with_crypto { SendChatTextJob.new.perform(encrypted_payload: encrypted_payload(serialized)) }
          end

          assert_equal true, sent.fetch(:request_phone)
          assert_equal "messenger", sent.fetch(:channel)
        end

        def test_long_cyrillic_links_consent_and_command_survive_encryption_and_dispatch
          url = "https://mi.example.test/mapa?stanica=nas"
          consent = "Ne šalji bez saglasnosti da tačna lokacija bude javna."
          command = "Odgovori: „Pošalji prijavu QA1234” ili „odustani”"
          serialized = enqueue_chat(text: ("Објашњење. " * 600) + "#{consent}\n#{url}\n#{command}")
          sent = nil
          client = Object.new
          client.define_singleton_method(:chat_channel_configured?) { |_channel| true }
          client.define_singleton_method(:send_chat_text) { |**attributes| sent = attributes }
          Client.stub(:new, client) do
            with_crypto { SendChatTextJob.new.perform(encrypted_payload: encrypted_payload(serialized)) }
          end

          text = sent.fetch(:text)
          assert text.valid_encoding?
          assert_operator text.bytesize, :<=, SendChatTextJob::MAX_REPLY_TEXT_BYTES
          [url, consent, command].each { |part| assert_includes text, part }
          assert_equal decrypt(serialized).fetch("text"), text
        end

        def test_phone_request_rejects_non_messenger_and_non_boolean_before_enqueue
          [
            { channel: "whatsapp", request_phone: true },
            { channel: "messenger", request_phone: "true" }
          ].each do |attributes|
            assert_raises(Error) { enqueue_chat(**attributes) }
          end

          assert_empty @adapter.enqueued_jobs
        end

        def test_retry_exhaustion_logs_only_safe_channel_status_code_and_group
          output = StringIO.new
          serialized = enqueue_chat
          payload = encrypted_payload(serialized)
          job = SendChatTextJob.allocate
          job.define_singleton_method(:arguments) { [{ encrypted_payload: payload }] }
          error = Error.new(
            "provider body userId=private-recipient text=Private citizen reply",
            http_status: 429,
            error_code: "RATE_LIMITED",
            error_group: "REJECTED"
          )

          Rails.stub(:logger, Logger.new(output)) do
            with_crypto { SendChatTextJob.log_exhausted_delivery(job, error) }
          end

          assert_includes output.string, "channel=whatsapp status=429 code=RATE_LIMITED group=REJECTED"
          refute_includes output.string, "private-recipient"
          refute_includes output.string, "Private citizen reply"
          refute_includes output.string, error.class.name
        end

        private

        def enqueue_chat(channel: "whatsapp", request_phone: false, **options)
          with_crypto do
            wait = options[:wait]
            target = wait ? SendChatTextJob.set(wait:) : SendChatTextJob
            target.perform_later(
              channel:,
              to: "private-recipient",
              text: options.fetch(:text, "Private citizen reply"),
              sender: "private-sender",
              request_phone:,
              organization_id: options[:organization_id],
              media_id: options[:media_id],
              expires_at: options[:expires_at]
            )
          end
          @adapter.enqueued_jobs.last
        end

        def encrypted_payload(serialized_job)
          serialized_job.fetch(:args).first.fetch("encrypted_payload")
        end

        def decrypt(serialized_job)
          with_crypto { SendChatTextJob.send(:decrypt_envelope, encrypted_payload(serialized_job)) }
        end

        def assert_ciphertext_only(serialized_job)
          arguments = serialized_job.fetch(:args)
          application_keys = arguments.first.keys - ["_aj_ruby2_keywords"]
          serialized = JSON.generate(arguments)

          assert_equal ["encrypted_payload"], application_keys
          assert_equal ["encrypted_payload"], arguments.first.fetch("_aj_ruby2_keywords")
          refute_includes serialized, "private-recipient"
          refute_includes serialized, "Private citizen reply"
          refute_includes serialized, "private-sender"
          refute_includes serialized, "request_phone"
        end

        def with_crypto
          application = Struct.new(:secret_key_base).new("engine-chat-job-test-secret")
          Rails.stub(:application, application) { yield }
        end
      end
    end
  end
end
