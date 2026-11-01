# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 2.6: optional traffic gets a local kill switch, and authentication
      # is proven to be outside its reach.
      #
      # The claim this file is NOT allowed to support, stated here as plainly as
      # it is stated in host:docs/operations/provider-eligibility.md:
      #
      #   **No same-sender template/config split guarantees protection from
      #   sender/business-account restrictions.**
      #
      # WhatsApp AUTH and WhatsApp UTILITY/MARKETING templates on one business
      # account share that account's standing. Splitting an application switch
      # buys a local kill switch and separate monitoring — nothing more. Every
      # test below is about what this REPOSITORY does; none of them is evidence
      # about what a provider will do.
      class MessagingRouterAuthIsolationTest < ActiveSupport::TestCase
        # Resolved lazily: a missing constant in a class body aborts the whole
        # harness at LOAD time, turning one red test into "no tests ran".
        def config = Decidim::Bih::Config

        def enrollment = Decidim::Bih::Messaging::Enrollment

        def outcome_module = Decidim::Bih::Messaging::Outcome

        SWITCH_ENV = "DECIDIM_BIH_OPTIONAL_TRAFFIC_DISABLED"
        PHONE = "+38765111222"
        ENROLLED_CLASS = "city.service_alert_viber"

        # The files that carry a citizen through sign-in and phone verification.
        # None of them may consult the optional-traffic switch, because a switch
        # that can stop authentication is not an optional-traffic switch.
        AUTHENTICATION_PATH_FILES = %w(
          app/services/decidim/bih/sms/infobip_gateway.rb
          app/jobs/decidim/bih/infobip/send_phone_message_job.rb
          app/jobs/decidim/bih/infobip/send_sms_job.rb
          app/controllers/decidim/bih/phone_sessions_controller.rb
          app/controllers/decidim/bih/phone_verification_controller.rb
          app/services/decidim/bih/phone_verification/complete.rb
          app/services/decidim/bih/phone_verification/attempt_limiter.rb
          app/services/decidim/bih/viber/queued_phone_message_gateway.rb
        ).freeze

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        teardown do
          ENV.delete(SWITCH_ENV)
          config.reset!
        end

        # Records everything the ordered phone-delivery policy was asked to
        # send, so "was the provider reached at all" is an assertion and not an
        # inference.
        class RecordingClient
          attr_reader :calls

          def initialize = @calls = []

          def configured? = true

          def viber_business_configured? = true

          def chat_channel_configured?(_channel) = false

          def send_phone_message(**kwargs)
            @calls << kwargs
            { "messages" => [{ "messageId" => "m-#{@calls.size}" }] }
          end

          def send_sms(**kwargs)
            @calls << kwargs.merge(channel: :sms)
            { "messages" => [{ "messageId" => "sms" }] }
          end
        end

        # Scripted per channel; every call is recorded with the template the
        # group carried, so "did an optional message borrow the AUTH template"
        # is answerable.
        class StubTransport
          attr_reader :calls

          def initialize(script)
            @script = script
            @calls = []
          end

          def call(channel:, channels:, group:, leg: nil)
            @calls << { channel: channel.to_s, channels: Array(channels).map(&:to_s),
                        template: group.template, endpoint_ref: leg && leg[:endpoint_ref] }
            scripted = @script.fetch(channel.to_sym)
            raise scripted if scripted.is_a?(StandardError)

            scripted
          end
        end

        def with_optional_traffic(enabled)
          previous = ENV.fetch(SWITCH_ENV, nil)
          ENV[SWITCH_ENV] = enabled ? nil : "true"
          config.reset!
          yield
        ensure
          ENV[SWITCH_ENV] = previous
          config.reset!
        end

        def pending_account_copy(topic: "community_news")
          Decidim::Bih::AccountNotification.create!(
            organization: @organization, user: @citizen, topic:,
            deduplication_digest: Digest::SHA256.hexdigest("auth-isolation:#{topic}:#{SecureRandom.hex(6)}"),
            expires_at: 1.hour.from_now,
            payload: { text: "Obavještenje", channels: %w(viber whatsapp) }
          )
        end

        def intent!(message_class: ENROLLED_CLASS)
          Decidim::Bih::Messaging::Intent.create!(
            organization: @organization, message_class:, recipient_kind: "account", user: @citizen,
            correlation_key: SecureRandom.hex(10), deduplication_scope: "auth-isolation",
            policy_version: "p1", eligibility_version: "e1", mode: "compatibility", status: "evaluated"
          )
        end

        def optional_group(channels:, template: nil)
          Decidim::Bih::Messaging::DeliveryGroup.new(
            name: "external_copy", channels: Array(channels).map(&:to_s), legs: [], group_mode: "fallback",
            fanout: "per_recipient", attempt_strategy: :sequential, content_variant: "community_news",
            content_variant_by_channel: {}, locale: "sr", template:, expires_at: 1.hour.from_now,
            dedup_identity: "community_news:external_copy:1", dedup_owner: "ledger",
            timeout_policy: Decidim::Bih::Messaging::Router::TIMEOUT_POLICY, fallback_owner: "producer",
            terminates_siblings: false, priority: "routine", preference_adapter: "community_news_topic",
            reason_codes: []
          ).frozen_copy
        end

        def definitive(code) = Decidim::Bih::Infobip::Error.new("refused", http_status: 400, error_code: code)

        def engine_file(relative) = Decidim::Bih::Engine.root.join(relative)

        # ---- the default: a deploy changes nothing ---------------------------

        test "the optional-traffic switch is on unless a host explicitly turns it off" do
          ENV.delete(SWITCH_ENV)
          config.reset!

          assert config.infobip[:optional_traffic_enabled],
                 "an absent environment variable must mean 'carry on exactly as today'"
        end

        test "only the documented variable turns it off, and it is an environment change" do
          with_optional_traffic(false) do
            refute config.infobip[:optional_traffic_enabled]
          end

          assert config.infobip[:optional_traffic_enabled], "the switch is restored when the variable goes away"
        end

        # ---- authentication is outside its reach -----------------------------

        test "disabling optional traffic leaves phone verification working" do
          with_optional_traffic(false) do
            client = RecordingClient.new
            gateway = Decidim::Bih::Sms::InfobipGateway.new(
              PHONE, "123456", { user: @citizen, organization: @organization }
            )
            gateway.instance_variable_set(:@client, client)

            assert gateway.deliver_code, "authentication must not be affected by the optional-traffic switch"
            assert_equal 1, client.calls.size
            assert_equal "123456", client.calls.first[:otp_code]
          end
        end

        test "disabling optional traffic leaves the queued authentication message sending" do
          with_optional_traffic(false) do
            client = RecordingClient.new
            Decidim::Bih::Infobip::Client.stub(:new, client) do
              Decidim::Bih::Infobip::SendPhoneMessageJob.perform_now(
                to: PHONE, text: "MI: 123456 je tvoj kod.", otp_code: "123456"
              )
            end

            assert_equal 1, client.calls.size, "the authentication job must reach the provider with the switch off"
          end
        end

        test "no file on the authentication path reads the optional-traffic switch" do
          AUTHENTICATION_PATH_FILES.each do |relative|
            path = engine_file(relative)

            assert_path_exists path, "#{relative} moved; this guard is only as good as its file list"
            refute_includes path.read, "optional_traffic",
                            "#{relative} is on the authentication path and must never consult the optional switch"
          end
        end

        test "the switch is read in exactly one place outside its own definition" do
          readers = Dir.glob(Decidim::Bih::Engine.root.join("app/**/*.rb")).select do |path|
            File.read(path).include?("optional_traffic_enabled")
          end

          assert_equal(["app/services/decidim/bih/account_notifications.rb"],
                       readers.map { |path| Pathname.new(path).relative_path_from(Decidim::Bih::Engine.root).to_s })
        end

        # ---- the optional path does stop, with its own reason -----------------

        test "disabling optional traffic skips an optional account copy with its own reason code" do
          notification = pending_account_copy

          with_optional_traffic(false) do
            Decidim::Bih::AccountNotifications.dispatch!(notification)
          end

          assert_equal "skipped", notification.reload.status
          assert_equal "optional_traffic_disabled", notification.reason
          assert_nil notification.attempted_at, "nothing may be claimed once the switch is off"
        end

        # Without this the test above would pass for the wrong reason: the same
        # citizen is ineligible anyway in a harness with no verified phone, so
        # "skipped" alone proves nothing. The REASON has to change with the
        # switch and only with the switch.
        test "with the switch on, the same message is refused for an eligibility reason instead" do
          notification = pending_account_copy

          with_optional_traffic(true) do
            Decidim::Bih::AccountNotifications.dispatch!(notification)
          end

          assert_equal "skipped", notification.reload.status
          refute_equal "optional_traffic_disabled", notification.reason
          assert_equal "ineligible", notification.reason
        end

        test "a message already past the switch is not rewritten by it" do
          notification = pending_account_copy
          notification.update!(status: "accepted", provider_message_ids: %w(m1))

          with_optional_traffic(false) do
            Decidim::Bih::AccountNotifications.dispatch!(notification)
          end

          assert_equal "accepted", notification.reload.status, "the switch never reopens settled work"
          assert_nil notification.reason
        end

        # ---- a refusal is never rerouted -------------------------------------

        test "a definitively rejected optional message is never rerouted through SMS or the AUTH template" do
          auth_template = { name: "mi_verify", language: "sr" }
          transport = StubTransport.new(viber: definitive("EC_NOT_REACHABLE"),
                                        whatsapp: definitive("EC_TEMPLATE_NOT_APPROVED"))
          group = optional_group(channels: %w(viber whatsapp), template: { name: "mi_community_news", language: "sr" })

          results = Decidim::Bih::Messaging::RoutedDispatch.new(group:, intent: intent!, transport:).call

          assert_equal(%w(viber whatsapp), transport.calls.map { |call| call[:channel] })
          assert_equal outcome_module::REJECTED, results.last.outcome
          refute(transport.calls.any? { |call| call[:channel] == "sms" },
                 "an optional message must never fall back to SMS")
          refute(transport.calls.any? { |call| call[:channels].include?("sms") })
          refute_includes transport.calls.map { |call| call[:template] }, auth_template
          refute_includes group.channels, "sms"
        end

        test "an optional group carries its own content variant, never the authentication one" do
          group = optional_group(channels: %w(viber))

          assert_equal "community_news", group.content_variant
          refute_equal "authentication", group.priority
        end

        # ---- two controls, not one -------------------------------------------

        test "the optional switch and the dispatch kill switch are independent controls" do
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                    "mode.#{ENROLLED_CLASS}", "compatibility")
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                    "dispatch_disabled.#{ENROLLED_CLASS}", true)

          with_optional_traffic(true) do
            assert config.infobip[:optional_traffic_enabled], "the per-organization kill switch does not move the global one"
            refute enrollment.dispatch_enabled?(organization: @organization, message_class: ENROLLED_CLASS)
            refute enrollment.routes?(organization: @organization, message_class: ENROLLED_CLASS)
          end
        end

        test "turning optional traffic off does not silently disable a routed sender's own controls" do
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                    "mode.#{ENROLLED_CLASS}", "compatibility")

          with_optional_traffic(false) do
            assert enrollment.dispatch_enabled?(organization: @organization, message_class: ENROLLED_CLASS),
                   "the environment switch is a separate control; it must not masquerade as the per-org one"
            assert_equal :compatibility, enrollment.mode(organization: @organization, message_class: ENROLLED_CLASS)
          end
        end
      end
    end
  end
end
