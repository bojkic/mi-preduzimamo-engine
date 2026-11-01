# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Phase 2 routing foundation (Tasks 2.0 and 2.1) against a real database.
      #
      # The pure suite proves the reader's and the router's own logic. This file
      # proves the two things a pure suite structurally cannot: that Enrollment
      # reads the REAL per-organization store Phase 1 built, and that
      # RoutedDispatch's claim/recheck/classify shape behaves correctly against
      # a real transport stub.
      #
      # Per-class enrollment files (report correspondence, city alerts,
      # campaign, auth isolation) are Tasks 2.3-2.6 and get their own files.
      class MessagingRouterTest < ActiveSupport::TestCase
        # Resolved lazily: a missing constant in a class body aborts the whole
        # harness at LOAD time, turning one red test into "no tests ran".
        def enrollment = Decidim::Bih::Messaging::Enrollment

        def modes_class = Decidim::Bih::Messaging::Modes

        def setting_class = Decidim::Bih::Setting

        # Read from the real registry rather than invented.
        ENROLLED_CLASS = "city.service_alert_viber"
        UNENROLLED_CLASS = "postal.verification_letter"

        setup do
          @organization = create_organization
          @other_organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def put!(organization, key, value)
          setting_class.put(organization, modes_class::NAMESPACE, key, value)
        end

        # ---- Task 2.0: the reader over the Phase 1 store ---------------------

        test "the stored mode is what Enrollment returns, per organization" do
          put!(@organization, "mode.#{ENROLLED_CLASS}", "compatibility")

          assert_equal :compatibility, enrollment.mode(organization: @organization, message_class: ENROLLED_CLASS)
          assert_equal :legacy, enrollment.mode(organization: @other_organization, message_class: ENROLLED_CLASS)
        end

        test "a mode change is visible to the next reader with no restart, which is what refresh_latency_seconds == 0 claims" do
          assert_equal :legacy, enrollment.mode(organization: @organization, message_class: ENROLLED_CLASS)

          put!(@organization, "mode.#{ENROLLED_CLASS}", "target")

          assert_equal :target, enrollment.mode(organization: @organization, message_class: ENROLLED_CLASS)
          assert_equal 0, enrollment.refresh_latency_seconds
        end

        test "a class the registry has not enrolled cannot be moved off legacy by a setting" do
          put!(@organization, "mode.#{UNENROLLED_CLASS}", "target")

          assert_equal :legacy, enrollment.mode(organization: @organization, message_class: UNENROLLED_CLASS)
          refute enrollment.routes?(organization: @organization, message_class: UNENROLLED_CLASS)
        end

        test "dispatch_disabled stops a routed sender without rolling its mode back" do
          put!(@organization, "mode.#{ENROLLED_CLASS}", "target")
          put!(@organization, "dispatch_disabled.#{ENROLLED_CLASS}", true)

          assert_equal :target, enrollment.mode(organization: @organization, message_class: ENROLLED_CLASS)
          refute enrollment.dispatch_enabled?(organization: @organization, message_class: ENROLLED_CLASS)
          refute enrollment.routes?(organization: @organization, message_class: ENROLLED_CLASS)
          assert enrollment.dispatch_enabled?(organization: @other_organization, message_class: ENROLLED_CLASS)
        end

        test "shadow observation is registry enrollment plus a legacy runtime mode" do
          assert enrollment.shadow_observed?(organization: @organization, message_class: ENROLLED_CLASS)

          put!(@organization, "mode.#{ENROLLED_CLASS}", "compatibility")

          refute enrollment.shadow_observed?(organization: @organization, message_class: ENROLLED_CLASS)
          assert enrollment.routes?(organization: @organization, message_class: ENROLLED_CLASS)
        end

        # ---- Task 2.1: the routing contract against the real Phase 1 ledger ---

        # Scripted per channel. Records every call so "was the transport reached
        # at all" is an assertion rather than an inference.
        class StubTransport
          attr_reader :calls

          def initialize(script)
            @script = script
            @calls = []
          end

          def call(channel:, channels:, group:, leg: nil)
            @calls << { channel: channel.to_s, channels: Array(channels).map(&:to_s),
                        endpoint_ref: leg && leg[:endpoint_ref], group: group.name }
            scripted = @script.fetch(channel.to_sym)
            raise scripted if scripted.is_a?(StandardError)

            scripted
          end
        end

        Refusal = Struct.new(:reason_codes) do
          def permitted? = false
        end

        def outcome_module = Decidim::Bih::Messaging::Outcome

        def router = Decidim::Bih::Messaging::Router

        def definitive(code) = Decidim::Bih::Infobip::Error.new("refused", http_status: 400, error_code: code)

        def uncertain(code) = Decidim::Bih::Infobip::Error.new("no reply", error_code: code)

        def accepted(id) = { "messages" => [{ "messageId" => id }] }

        def account_recipient
          Decidim::Bih::Messaging::RecipientContext.account(
            organization_id: @organization.id, account_id: @citizen.id, locale: "sr"
          )
        end

        def intent!(message_class: "report.case_message_to_author")
          Decidim::Bih::Messaging::Intent.create!(
            organization: @organization, message_class:, recipient_kind: "account", user: @citizen,
            correlation_key: SecureRandom.hex(10), deduplication_scope: "rails-harness",
            policy_version: "p1", eligibility_version: "e1", mode: "compatibility", status: "evaluated"
          )
        end

        # Built directly rather than through Router.plan: the registry has no
        # producer-owned fallback group today, and these examples are about what
        # RoutedDispatch does with one, not about what the registry declares.
        # rubocop:disable Metrics/ParameterLists
        def delivery_group(channels:, strategy: :sequential, group_mode: "fallback", fanout: "per_recipient",
                           legs: [], expires_at: nil, name: "phone_chain", fallback_owner: "producer")
          Decidim::Bih::Messaging::DeliveryGroup.new(
            name:, channels: Array(channels).map(&:to_s), legs:, group_mode:, fanout:,
            attempt_strategy: strategy, content_variant: "case_message", content_variant_by_channel: {},
            locale: "sr", template: nil, expires_at: expires_at || 1.hour.from_now,
            dedup_identity: "report.case_message_to_author:#{name}:1", dedup_owner: "ledger",
            timeout_policy: :uncertain_no_retry, fallback_owner:, terminates_siblings: false,
            priority: "transactional", preference_adapter: "report_updates_topic", reason_codes: []
          ).frozen_copy
        end
        # rubocop:enable Metrics/ParameterLists

        def dispatch(group, transport, policy_recheck: nil, intent: nil)
          Decidim::Bih::Messaging::RoutedDispatch.new(
            group:, intent: intent || intent!, transport:, policy_recheck:
          ).call
        end

        test "a definitive rejection falls through to the next channel in the group" do
          transport = StubTransport.new(viber: definitive("EC_NOT_REACHABLE"), whatsapp: accepted("m1"))

          results = dispatch(delivery_group(channels: %w(viber whatsapp)), transport)

          assert_equal(%w(viber whatsapp), transport.calls.map { |call| call[:channel] })
          assert_equal [outcome_module::REJECTED, outcome_module::ACCEPTED], results.map(&:outcome)
          assert_equal %w(m1), results.last.provider_ids
        end

        test "an uncertain outcome STOPS the group and never tries the next channel" do
          transport = StubTransport.new(viber: uncertain("EC_TIMEOUT"), whatsapp: accepted("m1"))

          results = dispatch(delivery_group(channels: %w(viber whatsapp)), transport)

          assert_equal(%w(viber), transport.calls.map { |call| call[:channel] })
          assert_equal [outcome_module::UNCERTAIN], results.map(&:outcome)
        end

        test "a response with no provider id is uncertain and also stops the group" do
          transport = StubTransport.new(viber: { "messages" => [] }, whatsapp: accepted("m1"))

          results = dispatch(delivery_group(channels: %w(viber whatsapp)), transport)

          assert_equal(%w(viber), transport.calls.map { |call| call[:channel] })
          assert_equal outcome_module::UNCERTAIN, results.last.outcome
          assert_equal "missing_provider_id", results.last.reason
        end

        test "an expired payload is skipped before any transport call" do
          transport = StubTransport.new(viber: accepted("m1"))

          results = dispatch(delivery_group(channels: %w(viber), expires_at: 1.second.ago), transport)

          assert_empty transport.calls
          assert_equal outcome_module::EXPIRED, results.last.outcome
          assert_equal "expired", results.last.reason
        end

        test "a late STOP found after the claim prevents the send" do
          transport = StubTransport.new(viber: accepted("m1"))
          intent = intent!
          rechecked = []
          refuse = lambda do |channel:|
            rechecked << channel
            Refusal.new([:transport_suppressed])
          end

          results = dispatch(delivery_group(channels: %w(viber)), transport, policy_recheck: refuse, intent:)

          assert_equal %w(viber), rechecked, "the recheck runs, and it runs per channel"
          assert_empty transport.calls
          assert_equal outcome_module::SKIPPED, results.last.outcome
          assert_equal "transport_suppressed", results.last.reason
          assert_equal %w(skipped), intent.attempts.reload.map(&:status)
        end

        test "one failed push endpoint does not resend to the others and does not fall back" do
          transport = StubTransport.new(push: uncertain("EC_GONE"))
          legs = %w(ep-a ep-b ep-c).map { |ref| { endpoint_ref: ref, outcome: outcome_module::QUEUED } }
          group = delivery_group(channels: %w(push), strategy: :parallel, group_mode: "parallel",
                                 fanout: "per_device", legs:, name: "push", fallback_owner: "none")

          results = dispatch(group, transport)

          assert_equal(%w(ep-a ep-b ep-c), transport.calls.map { |call| call[:endpoint_ref] })
          assert_equal 3, results.size
          assert(results.all? { |result| result.outcome == outcome_module::UNCERTAIN })
        end

        test "a provider-owned chain is one request carrying every channel" do
          transport = StubTransport.new(viber: accepted("m1"))
          group = delivery_group(channels: %w(viber whatsapp), strategy: :single_request,
                                 group_mode: "single", fallback_owner: "provider", name: "external_copy")

          results = dispatch(group, transport)

          assert_equal 1, transport.calls.size
          assert_equal %w(viber whatsapp), transport.calls.first[:channels]
          assert_equal outcome_module::ACCEPTED, results.last.outcome
        end

        test "a revoked social session is a definitive rejection of that channel, not a phone fallback" do
          transport = StubTransport.new(messenger: definitive("EC_SESSION_EXPIRED"))
          group = delivery_group(channels: %w(messenger), name: "external_copy")

          results = dispatch(group, transport)

          assert_equal outcome_module::REJECTED, results.last.outcome
          refute_includes transport.calls.map { |call| call[:channel] }, "sms"
          refute_includes group.channels, "sms"
        end

        test "every attempt is settled in the Phase 1 ledger with the router's own classification" do
          transport = StubTransport.new(viber: definitive("EC_NOT_REACHABLE"), whatsapp: accepted("m1"))
          intent = intent!

          dispatch(delivery_group(channels: %w(viber whatsapp)), transport, intent:)
          attempts = intent.attempts.reload.order(:id)

          assert_equal %w(viber whatsapp), attempts.map(&:channel)
          assert_equal %w(failed accepted), attempts.map(&:status)
          assert_equal %w(phone_chain phone_chain), attempts.map(&:channel_group)
          assert_equal "EC_NOT_REACHABLE", attempts.first.reason
          assert_equal "m1", attempts.last.provider_message_id
          assert(attempts.all? { |attempt| attempt.settled_at.present? })
        end

        test "the Outcome vocabulary maps onto statuses the Attempt model accepts" do
          outcome_module::ATTEMPT_STATUS.each_value do |status|
            assert_includes Decidim::Bih::Messaging::Attempt::STATUSES, status
          end
          assert_equal outcome_module::ALL.sort, outcome_module::ATTEMPT_STATUS.keys.sort
        end

        # ---- Task 2.1: the router against the real Policy ---------------------

        test "a plan built with the real Policy is frozen, fully reasoned and carries Phase 1 versions" do
          plan = router.plan(message_class: "report.case_message_to_author", recipient: account_recipient,
                             organization: @organization, context: {}, mode: :compatibility)

          assert_predicate plan, :frozen?
          assert(plan.groups.none? { |group| group.channels.empty? }, "a group with no channel must be dropped")
          assert(plan.suppressed.all? { |entry| entry[:reason_codes].any? }, "every suppression carries a reason")
          assert(plan.groups.none?(&:terminates_siblings))
          assert_equal Decidim::Bih::Messaging::Policy::POLICY_VERSION, plan.policy_version
          assert_equal Decidim::Bih::Messaging::Policy::ELIGIBILITY_VERSION, plan.eligibility_version
        end

        test "the router resolves its own mode through Enrollment when the caller passes none" do
          put!(@organization, "mode.report.case_message_to_author", "compatibility")

          plan = router.plan(message_class: "report.case_message_to_author", recipient: account_recipient,
                             organization: @organization, context: {})

          assert_equal :compatibility, plan.mode
        end

        test "a plan for another organization's recipient produces no groups" do
          stranger = Decidim::Bih::Messaging::RecipientContext.account(
            organization_id: @other_organization.id, account_id: @citizen.id, locale: "sr"
          )

          plan = router.plan(message_class: "report.case_message_to_author", recipient: stranger,
                             organization: @organization, context: {}, mode: :compatibility)

          assert_empty plan.groups
          assert_includes plan.suppressed.flat_map { |entry| entry[:reason_codes] }, :wrong_tenant
        end
      end
    end
  end
end
