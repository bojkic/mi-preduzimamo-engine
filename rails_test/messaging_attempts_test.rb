# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 3.1 — one attempt row per REAL delivery leg, and not one more.
      #
      # The whole value of this ledger is that it refuses to flatten four
      # different kinds of evidence into one word:
      #
      #   * a bell row exists            → the citizen has an inbox entry, and
      #                                    `decidim_notifications` has no read_at
      #                                    at all, so nothing here can say more;
      #   * a push service returned 201  → it took the request; no browser ever
      #                                    acknowledged displaying anything;
      #   * SMTP returned without raising→ the next hop took the message; that is
      #                                    not inbox placement and not reading;
      #   * a provider report said
      #     DELIVERED_TO_HANDSET         → the only thing in this system that may
      #                                    ever be called `delivered`.
      #
      # And the rows themselves carry no raw destination, no token and no body:
      # a destination is a kind plus a SHA256 digest, a device is the
      # fingerprint that already exists for that purpose, never the endpoint URL.
      class MessagingAttemptsTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        ATTEMPT = Decidim::Bih::Messaging::Attempt
        INTENT = Decidim::Bih::Messaging::Intent
        OUTCOME = Decidim::Bih::Messaging::Outcome
        CORRELATION = Decidim::Bih::Messaging::Correlation
        KEY = Decidim::Bih::Messaging::SuppressionKey
        RECORDER = Decidim::Bih::Messaging::MailRecorder
        STATUS_COPY_CLASS = "report.author_external_copy"
        PHONE = "+38765111001"

        class ClientDouble
          attr_accessor :response
          attr_reader :calls

          def initialize = @calls = []

          def configured? = true

          def viber_business_configured? = true

          def chat_channel_configured?(_channel) = false

          def message_delivery_reports(**) = { "results" => [] }

          def send_phone_message(**options)
            @calls << options
            response || { "messages" => [{ "messageId" => "provider-viber" }, { "messageId" => "provider-whatsapp" }] }
          end
        end

        # A push service's refusal is a ResponseError, which reads `body` off
        # its response in the constructor; `nil` blows up before the test can
        # assert anything about it.
        PushResponse = Struct.new(:body, :code)

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          # The staff-alert bells need somebody to alert; without a recipient
          # the job creates no notifications and the test proves nothing.
          @staff = FactoryBot.create(:user, :confirmed, organization: @organization, admin: true)
          @client = ClientDouble.new
          Decidim::Bih::MailHooks.install!
        end

        def push_error(klass, body: "gone", code: "410")
          klass.new(PushResponse.new(body, code), "push.example.org")
        end

        def messaging = Decidim::Bih::Messaging

        def enroll!(message_class, mode)
          Decidim::Bih::Setting.put(@organization, messaging::Modes::NAMESPACE, "mode.#{message_class}", mode)
        end

        def with_delivery(&)
          Decidim::Bih::Infobip::Client.stub(:new, @client) do
            Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, PHONE, &)
          end
        end

        def subscription(auth)
          { "endpoint" => "https://fcm.googleapis.com/fcm/send/#{auth}", "p256dh" => "key-#{auth}", "auth" => auth }
        end

        def subscribe!(*auths)
          settings = @user.notification_settings.to_h.deep_dup
          settings["subscriptions"] = auths.index_with { |auth| subscription(auth) }
          @user.update!(notification_settings: settings)
          auths.map { |auth| Decidim::Bih::WebPush.fingerprint(subscription(auth)) }
        end

        def push_intent
          Decidim::Bih::WebPush.fanout_intent(@user, "notifications")
        end

        def deliver_push(fingerprint, intent, raising: nil)
          sender = lambda do |**_args|
            @push_http_calls = (@push_http_calls || 0) + 1
            raise raising if raising

            { ok: true }
          end
          Decidim::Bih::WebPush.stub(:enabled?, true) do
            ::WebPush.stub(:payload_send, sender) do
              Decidim::Bih::WebPushDeliveryJob.perform_now(@user.id, fingerprint, "notifications", intent&.id)
            end
          end
        end

        def build_report(status: "u_obradi", email: "kontakt@example.org")
          Decidim::Bih::Report.create!(organization: @organization, author: @user, description: "Broken pavement.",
                                       category: "putevi", severity: "normalan", status:, address: "Harness 1",
                                       reporter_email: email, latitude: 44.758, longitude: 19.214)
        end

        # ---- the account external copy --------------------------------------

        test "a provider-managed chain is ONE request and therefore ONE attempt, carrying every id it answered with" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          [:viber, :whatsapp].each { |channel| Decidim::Bih::NotificationPreferences.set!(@user, topic: :report_updates, channel:, enabled: true) }
          notification = Decidim::Bih::AccountNotifications.enqueue!(
            user: @user, organization: @organization, topic: :report_updates, text: "Novi status.",
            deduplication_key: "report:1:u_obradi", channels: %w(viber whatsapp),
            message_class: STATUS_COPY_CLASS, enqueue_job: false
          )

          with_delivery { Decidim::Bih::AccountNotifications.dispatch!(notification) }

          intent = INTENT.find_by(account_notification: notification)
          attempts = ATTEMPT.where(intent:)
          assert_equal 1, attempts.count, "one provider request is one leg, however many channels it carried"
          attempt = attempts.first
          assert_equal "accepted", attempt.status
          assert_equal %w(provider-viber provider-whatsapp), attempt.provider_message_ids,
                       "a chain answers with one id PER CHANNEL; dropping all but the first loses a leg's reports"
          assert_not_nil attempt.accepted_at
          assert_nil attempt.resolved_at, "the provider took the request; nothing has been delivered yet"
          assert_equal 1, @client.calls.size
        end

        # `AccountNotifications#routed_dispatch!` rescues StandardError, so a
        # LOAD error anywhere in the routed path degrades silently to "unknown"
        # instead of failing where somebody would see it. This pins the two
        # constants that are easiest to get wrong — `Outcome` inside
        # `DispatchEvidence` resolves to a local Struct, not to the vocabulary.
        test "the ledger's terminal and acceptance vocabularies are the Outcome vocabulary" do
          evidence = Decidim::Bih::Messaging::DispatchEvidence

          assert_equal OUTCOME::TERMINAL.map { |outcome| OUTCOME.attempt_status(outcome) }.uniq.sort,
                       evidence::TERMINAL_STATUSES.sort
          assert_equal %w(accepted delivered), evidence::ACCEPTANCE_STATUSES.sort
          assert_not_includes evidence::TERMINAL_STATUSES, "uncertain",
                              "an uncertain leg is waiting for reconciliation, not finished"
        end

        test "the external copy attempt records the destination as a kind and a digest, never the number" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          [:viber, :whatsapp].each { |channel| Decidim::Bih::NotificationPreferences.set!(@user, topic: :report_updates, channel:, enabled: true) }
          notification = Decidim::Bih::AccountNotifications.enqueue!(
            user: @user, organization: @organization, topic: :report_updates, text: "Novi status.",
            deduplication_key: "report:2:u_obradi", channels: %w(viber whatsapp),
            message_class: STATUS_COPY_CLASS, enqueue_job: false
          )

          with_delivery { Decidim::Bih::AccountNotifications.dispatch!(notification) }

          attempt = ATTEMPT.where(intent: INTENT.find_by(account_notification: notification)).first
          assert_equal "phone", attempt.destination_kind
          assert_equal KEY.digest(kind: :phone, value: PHONE), attempt.destination_digest
          refute_includes attempt.attributes.to_json, "38765111001"
        end

        # ---- per-device push -------------------------------------------------

        test "push fans out to one attempt per endpoint, each with its own outcome" do
          fingerprints = subscribe!("ep-a", "ep-b")
          intent = push_intent
          deliver_push(fingerprints.first, intent)
          deliver_push(fingerprints.last, intent, raising: push_error(::WebPush::ExpiredSubscription))

          rows = ATTEMPT.where(intent:, channel: "push").order(:id)
          assert_equal 2, rows.count
          assert_equal fingerprints, rows.map(&:destination_version)
          assert_equal %w(accepted expired), rows.map(&:status)
          assert_equal 1, INTENT.where(id: intent.id).count, "one fan-out is ONE logical message"
        end

        test "an expired push subscription is removed AND the reason survives the removal" do
          fingerprint = subscribe!("ep-gone").first
          intent = push_intent
          deliver_push(fingerprint, intent, raising: push_error(::WebPush::ExpiredSubscription))

          assert_empty @user.reload.notification_settings.fetch("subscriptions", {}),
                       "an expired subscription is removed"
          attempt = ATTEMPT.find_by(intent:, channel: "push")
          assert_equal "expired", attempt.status
          assert_equal "subscription_expired", attempt.reason
        end

        test "a push attempt stores the device fingerprint and never the endpoint URL" do
          fingerprint = subscribe!("ep-a").first
          intent = push_intent
          deliver_push(fingerprint, intent)

          attempt = ATTEMPT.find_by(intent:, channel: "push")
          assert_equal "push_endpoint", attempt.destination_kind
          refute_includes attempt.attributes.to_json, "fcm.googleapis.com"
          refute_includes attempt.attributes.to_json, "https://"
        end

        test "repeated jobs preserve an uncertain push outcome without a second HTTP attempt" do
          fingerprint = subscribe!("ep-a").first
          intent = push_intent
          assert_no_enqueued_jobs do
            deliver_push(fingerprint, intent, raising: push_error(::WebPush::PushServiceError, body: "later", code: "503"))
          end
          assert_equal "uncertain", ATTEMPT.find_by(intent:, channel: "push").status

          deliver_push(fingerprint, intent)

          rows = ATTEMPT.where(intent:, channel: "push")
          assert_equal 1, rows.count, "the same device is one leg across a retry"
          assert_equal "uncertain", rows.first.status
          assert_equal 1, @push_http_calls, "an uncertain response cannot authorize another copy"
        end

        test "a topic disabled after enqueue settles the claimed push as skipped without HTTP" do
          fingerprint = subscribe!("ep-a").first
          intent = push_intent
          Decidim::Bih::TopicPreferences.set!(@user, topic: :report_updates, enabled: false)

          assert_no_enqueued_jobs { deliver_push(fingerprint, intent) }

          attempt = ATTEMPT.find_by(intent:, channel: "push")
          assert_equal "skipped", attempt.status
          assert_equal "eligibility_changed", attempt.reason
          assert_nil @push_http_calls
        end

        test "a job enqueued before this release carries no intent and still runs" do
          fingerprint = subscribe!("ep-a").first

          deliver_push(fingerprint, nil)

          assert_equal 0, ATTEMPT.count, "an uncorrelated leg is a visible gap, not a crash"
        end

        # ---- bell creation ---------------------------------------------------

        test "a bell creation is recorded as bell_created and resolves nothing about the device" do
          report = build_report
          message = Decidim::Bih::ReportMessage.create!(report:, actor_role: "citizen", actor: @user,
                                                        kind: "question", body: "Ima li novosti?")

          Decidim::Bih::ReportStaffAlertJob.perform_now(report.id)

          attempt = ATTEMPT.joins(:intent)
                           .find_by(decidim_bih_messaging_intents: { message_class: "report.staff_alert" }, channel: "bell")
          assert_not_nil attempt, "staff #{@staff.id} and message #{message.id} exist; the bell leg must too"
          assert_equal "accepted", attempt.status
          assert_equal "bell_created", attempt.reason
          assert_nil attempt.resolved_at, "creating an inbox row resolves nothing about a device"
          assert_nil attempt.destination_digest, "a bell has no transport destination"
          assert_equal "account", attempt.destination_kind
        end

        test "a bell the citizen later deletes does not change what its attempt observed" do
          report = build_report
          Decidim::Bih::ReportStaffAlertJob.perform_now(report.id)
          attempt = ATTEMPT.joins(:intent)
                           .find_by(decidim_bih_messaging_intents: { message_class: "report.staff_alert" }, channel: "bell")

          Decidim::Notification.find(attempt.destination_version.to_i).destroy!

          assert_equal "accepted", attempt.reload.status
          assert_equal "bell_created", attempt.reason
        end

        test "a ledger that will not write never costs an operator their bell" do
          report = build_report

          CORRELATION.stub(:observe!, ->(**) { raise ActiveRecord::StatementInvalid, "ledger down" }) do
            Decidim::Bih::ReportStaffAlertJob.perform_now(report.id)
          end

          assert Decidim::Notification.exists?(event_name: Decidim::Bih::ReportStaffAlertJob::EVENT_NAME),
                 "the bell is the message; the ledger row is only the observation of it"
          assert_equal 0, ATTEMPT.count
        end

        # ---- mail ------------------------------------------------------------

        test "SMTP acceptance is its own observation and claims nothing about delivery" do
          Decidim::Bih::RegistrationMailer.resume(@user, "tok").deliver_now

          attempt = ATTEMPT.joins(:intent)
                           .find_by(decidim_bih_messaging_intents: { message_class: "registration.resume_email" })
          assert_equal "accepted", attempt.status
          assert_equal "smtp_accepted", attempt.reason
          assert_not_nil attempt.accepted_at
          assert_nil attempt.resolved_at, "acceptance by the next hop resolves nothing"
          refute_equal "delivered", attempt.status
        end

        test "the internal correlation header is stripped before the message leaves the building" do
          mail = Decidim::Bih::RegistrationMailer.resume(@user, "tok")
          assert_not_nil mail[RECORDER::HEADER], "the mailer stamps it"

          mail.deliver_now

          assert_nil mail[RECORDER::HEADER], "and the interceptor removes it"
          assert_not_includes ActionMailer::Base.deliveries.last.to_s, RECORDER::HEADER
        end

        test "the mail correlation key is the citizen's own id and never the pending token" do
          Decidim::Bih::RegistrationMailer.resume(@user, "a-live-pending-token").deliver_now

          intent = INTENT.find_by(message_class: "registration.resume_email")
          assert_equal "registration_resume:#{@user.id}", intent.correlation_key
          refute_includes intent.attributes.to_json, "a-live-pending-token"
        end

        test "a recipient with no account uses a scoped safe reference, not a user id" do
          report = build_report
          Decidim::Bih::ReporterMailer.status_update(report, locale: "sr", host: @organization.host).deliver_now

          intent = INTENT.find_by(message_class: "report.reporter_status_email")
          assert_equal "anonymous_report_contact", intent.recipient_kind
          assert_nil intent.decidim_user_id, "a contact address is never resolved into an account"
          assert_equal 64, intent.recipient_reference.to_s.length
          refute_includes intent.recipient_reference.to_s, "kontakt"
        end

        # Owner decision D11: a monitored reply mailbox, on EVERY message.
        test "every outbound message carries the monitored reply mailbox" do
          Decidim::Bih.stub(:mailer_reply_to, "bojan@example.org") do
            Decidim::Bih::RegistrationMailer.resume(@user, "tok").deliver_now
            Decidim::Bih::EmailConfirmationMailer.confirm(@user, "tok").deliver_now
          end

          replies = ActionMailer::Base.deliveries.last(2).map(&:reply_to)
          assert_equal [["bojan@example.org"], ["bojan@example.org"]], replies,
                       "the interceptor covers mailers that do not inherit from Decidim::ApplicationMailer"
        end

        test "an unconfigured host gets no invented reply address" do
          Decidim::Bih.stub(:mailer_reply_to, nil) do
            Decidim::Bih::RegistrationMailer.resume(@user, "tok").deliver_now
          end

          assert_nil ActionMailer::Base.deliveries.last.reply_to,
                     "a reusable engine must never point another organization's replies at a mailbox they do not own"
        end

        test "a reply_to a mailer chose deliberately is not overwritten" do
          Decidim::Bih.stub(:mailer_reply_to, "bojan@example.org") do
            mail = Decidim::Bih::RegistrationMailer.resume(@user, "tok")
            mail.reply_to = "case-42@example.org"
            mail.deliver_now
          end

          assert_equal ["case-42@example.org"], ActionMailer::Base.deliveries.last.reply_to
        end

        test "an unenrolled mailer is left alone rather than half-recorded" do
          Decidim::Bih::EmailConfirmationMailer.confirm(@user, "confirmation-token").deliver_now

          assert_equal 0, INTENT.where(message_class: "account.email_confirmation").count
        end

        # ---- what a row may never contain -----------------------------------

        test "no attempt row anywhere carries a raw destination, a bearer link or a body" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          [:viber, :whatsapp].each { |channel| Decidim::Bih::NotificationPreferences.set!(@user, topic: :report_updates, channel:, enabled: true) }
          notification = Decidim::Bih::AccountNotifications.enqueue!(
            user: @user, organization: @organization, topic: :report_updates, text: "Novi status.",
            deduplication_key: "report:9:u_obradi", channels: %w(viber whatsapp),
            message_class: STATUS_COPY_CLASS, enqueue_job: false
          )
          with_delivery { Decidim::Bih::AccountNotifications.dispatch!(notification) }
          subscribe!("ep-a").each { |fingerprint| deliver_push(fingerprint, push_intent) }
          Decidim::Bih::RegistrationMailer.resume(@user, "tok").deliver_now

          serialized = ATTEMPT.all.map { |attempt| attempt.attributes.to_json }.join
          assert_operator ATTEMPT.count, :>=, 3
          refute_match(/@/, serialized, "no raw e-mail address")
          refute_match(/\+387/, serialized, "no raw phone number")
          refute_match(%r{https://}, serialized, "no bearer link and no endpoint URL")
          refute_match(/Novi status/, serialized, "no message body")
        end

        # ---- Task 3.2: say exactly what is known -----------------------------

        def claimed_phone_attempt
          intent = INTENT.create!(organization: @organization, user: @user, message_class: STATUS_COPY_CLASS,
                                  recipient_kind: "account", correlation_key: "leg-#{SecureRandom.hex(4)}",
                                  deduplication_scope: "#{STATUS_COPY_CLASS}:external_copy",
                                  policy_version: "v", eligibility_version: "v", mode: "shadow", status: "recorded")
          intent.attempts.create!(channel_group: "external_copy", channel: "viber", status: "claimed",
                                  claimed_at: Time.current, destination_kind: "phone",
                                  destination_digest: KEY.digest(kind: :phone, value: PHONE))
        end

        def report_for(name:, group: nil, message_id: "m1")
          { "messageId" => message_id, "status" => { "name" => name, "groupName" => group }.compact }
        end

        test "provider acceptance and provider delivery are two observations of one attempt" do
          attempt = claimed_phone_attempt
          attempt.observe!(outcome: OUTCOME::ACCEPTED, provider_message_ids: %w(m1))

          assert_nil attempt.reload.resolved_at, "acceptance resolves nothing"
          assert_not_nil attempt.accepted_at

          attempt.observe!(outcome: OUTCOME::DELIVERED, at: 5.seconds.from_now)

          assert_equal "delivered", attempt.reload.status
          assert_not_nil attempt.resolved_at
          assert_operator attempt.accepted_at, :<, attempt.resolved_at
        end

        test "a delivered attempt is never downgraded by a later PENDING_ENROUTE report" do
          attempt = claimed_phone_attempt
          attempt.observe!(outcome: OUTCOME::DELIVERED)
          attempt.observe!(outcome: OUTCOME::ACCEPTED)

          assert_equal "delivered", attempt.reload.status
        end

        test "an uncertain attempt is never reset to pending by a later observation" do
          attempt = claimed_phone_attempt
          attempt.observe!(outcome: OUTCOME::UNCERTAIN, reason: "worker_interrupted")
          attempt.observe!(outcome: OUTCOME::QUEUED)

          assert_equal "uncertain", attempt.reload.status
          assert_equal "worker_interrupted", attempt.reason
        end

        test "a claim settles nothing, and a later observation is what settles it" do
          attempt = claimed_phone_attempt
          attempt.observe!(outcome: OUTCOME::CLAIMED)

          assert_nil attempt.reload.settled_at, "a leg still waiting must not read as finished"

          attempt.observe!(outcome: OUTCOME::ACCEPTED)

          assert_not_nil attempt.reload.settled_at
        end

        test "a definitive rejection is not recorded as an acceptance" do
          attempt = claimed_phone_attempt
          attempt.observe!(outcome: OUTCOME::REJECTED, reason: "EC_ABSENT_SUBSCRIBER")

          assert_equal "failed", attempt.reload.status, "Attempt::STATUSES has no rejected of its own"
          assert_nil attempt.accepted_at, "the provider answered, and it answered never"
          assert_not_nil attempt.resolved_at
        end

        test "a delivery report is attached to the leg its own provider id belongs to" do
          enroll!(STATUS_COPY_CLASS, "compatibility")
          [:viber, :whatsapp].each { |channel| Decidim::Bih::NotificationPreferences.set!(@user, topic: :report_updates, channel:, enabled: true) }
          notification = Decidim::Bih::AccountNotifications.enqueue!(
            user: @user, organization: @organization, topic: :report_updates, text: "Novi status.",
            deduplication_key: "report:3:u_obradi", channels: %w(viber whatsapp),
            message_class: STATUS_COPY_CLASS, enqueue_job: false
          )
          with_delivery { Decidim::Bih::AccountNotifications.dispatch!(notification) }
          attempt = ATTEMPT.where(intent: INTENT.find_by(account_notification: notification)).first
          assert_equal "accepted", attempt.reload.status

          # The report arrives for the SECOND id of the chain, which the single
          # `provider_message_id` column never held.
          @client.define_singleton_method(:message_delivery_reports) do |message_id:|
            next { "results" => [] } unless message_id == "provider-whatsapp"

            { "results" => [{ "messageId" => "provider-whatsapp",
                              "status" => { "name" => "DELIVERED_TO_HANDSET", "groupName" => "DELIVERED" } }] }
          end
          with_delivery { Decidim::Bih::AccountNotifications.reconcile!(notification.reload) }

          assert_equal "delivered", attempt.reload.status
          assert_equal "DELIVERED_TO_HANDSET", attempt.reason
        end

        test "only an explicit DELIVERED_TO_HANDSET report produces a delivered leg" do
          attempt = claimed_phone_attempt
          attempt.observe!(outcome: OUTCOME::ACCEPTED, provider_message_ids: %w(m1))

          %w(PENDING_ENROUTE PENDING_WAITING_DELIVERY).each do |name|
            outcome = OUTCOME.classify(report: report_for(name:, group: "PENDING"), previous: :accepted)
            attempt.observe!(outcome:)
            assert_equal "accepted", attempt.reload.status, "#{name} is not delivery"
          end

          attempt.observe!(outcome: OUTCOME.classify(report: report_for(name: "DELIVERED_TO_HANDSET", group: "DELIVERED"),
                                                     previous: :accepted))
          assert_equal "delivered", attempt.reload.status
        end

        # An allowlist rather than a text scan for the word: every file that
        # names the constant is listed here with the reason it is a READ. A new
        # writer fails this test and forces the decision to be made on purpose.
        test "the only places that name Outcome::DELIVERED are reads, and they are listed" do
          # The engine's own root, not a path relative to this file: this test
          # has to mean the same thing wherever the harness runs it from.
          root = Decidim::Bih::Engine.root.join("app")
          files = Dir[File.join(root, "**", "*.rb")].select { |file| File.read(file).match?(/Outcome::DELIVERED\b/) }

          assert_equal %w(attempt.rb routed_dispatch.rb), files.map { |file| File.basename(file) }.sort,
                       "attempt.rb reads it to decide accepted_at; routed_dispatch.rb reads back a row that already is delivered"
        end

        # Deliberately narrow. Migrations that write data DO exist and are
        # legitimate — a nullable column, an anonymisation, a cached aggregate.
        # The rule is not "no migration writes"; it is that no migration invents
        # a DELIVERY on rows that never carried delivery evidence.
        test "no migration writes a delivery onto historical rows" do
          root = Decidim::Bih::Engine.root.join("db", "migrate")
          backfills = Dir[File.join(root, "*.rb")].select do |file|
            body = File.read(file)
            body.match?(/delivered/i) && body.match?(/update_all|UPDATE\s|insert_all/i)
          end

          assert_empty backfills.map { |file| File.basename(file) },
                       "a delivered status may only come from an explicit provider report"
        end

        test "the messaging services do not reach into the operator, governance or feedback ledgers" do
          root = Decidim::Bih::Engine.root.join("app", "services", "decidim", "bih", "messaging")
          offenders = Dir[File.join(root, "*.rb")].select do |file|
            body = File.read(file)
            # Candidate selection may read the current provider launch approval.
            # It may not create or mutate governance history.
            body = body.gsub("GovernanceApproval.current_for", "") if File.basename(file) == "broadcast_channels.rb"
            body.match?(/OperatorAuditEvent|GovernanceApproval|ConciergeFeedback/)
          end

          assert_empty offenders.map { |file| File.basename(file) },
                       "those are independent records with their own retention and access rules"
        end
      end
    end
  end
end
