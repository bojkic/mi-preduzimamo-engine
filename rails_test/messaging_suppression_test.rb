# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 3.4 — the transport suppression store, and the precedence it takes.
      #
      # A suppression is not a topic choice. Keeping them apart is the whole
      # point: a citizen who wrote STOP to the provider has told the TRANSPORT
      # to stop, and an unrelated settings save must not be able to undo that
      # by accident. So there are two stores, they are written together, and
      # only one of them can be cleared by a grid.
      #
      # The store keys on tenant + provider + channel + normalized destination
      # digest + address version. Never on a delivery id: a delivery id
      # identifies one message, and a refusal is about a destination.
      class MessagingSuppressionTest < ActiveSupport::TestCase
        SUPPRESSION = Decidim::Bih::Messaging::Suppression
        STORE = Decidim::Bih::Messaging::TransportSuppression
        KEY = Decidim::Bih::Messaging::SuppressionKey
        PHONE = "+38765111001"
        OTHER_PHONE = "+38765222002"

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def digest(value, kind: :phone) = KEY.digest(kind:, value:)

        def stop!(value: PHONE, channel: "viber", reason: "provider_opt_out", event_ref: nil, occurred_at: nil)
          STORE.ingest!(organization: @organization, provider: "infobip", channel:,
                        destination: { kind: :phone, value: }, reason:, source: "provider_webhook",
                        event_ref:, occurred_at:)
        end

        def blocking?(value: PHONE, channel: "viber")
          SUPPRESSION.blocking?(organization: @organization, provider: "infobip", channel:,
                                destination_digest: digest(value))
        end

        # ---- what it keys on -------------------------------------------------

        test "a suppression is keyed by destination identity, never by a delivery id" do
          record = stop!

          assert_equal digest(PHONE), record.destination_digest
          assert_equal 1, record.address_version
          assert_nil SUPPRESSION.column_names.find { |name| name.include?("message_id") },
                     "a refusal is about a destination, not about one message"
          refute_includes record.attributes.to_json, "38765111001"
        end

        test "a different phone is a different identity and inherits nothing" do
          stop!

          assert blocking?
          assert_not blocking?(value: OTHER_PHONE),
                     "a changed address is a new destination version, not an inherited failure"
        end

        test "the same number written two ways is one identity" do
          stop!(value: "+387 65 111-001")

          assert blocking?(value: "+38765111001")
        end

        test "a suppression on one channel does not silence another" do
          stop!(channel: "viber")

          assert blocking?(channel: "viber")
          assert_not blocking?(channel: "whatsapp")
        end

        test "a STOP with no account behind it is still recorded" do
          record = stop!(value: "+38765999999")

          assert_nil record.decidim_user_id
          assert record.blocking?, "a refusal from a number nobody owns is still a refusal"
        end

        # ---- five reasons, five meanings -------------------------------------

        test "a hard bounce, a complaint, a temporary failure, an unsubscribe and a provider STOP are five reasons" do
          %w(hard_bounce complaint temporary_failure optional_unsubscribe provider_opt_out).each_with_index do |reason, index|
            record = STORE.ingest!(organization: @organization, provider: "smtp", channel: "email",
                                   destination: { kind: :email, value: "#{reason}@example.org" },
                                   reason:, source: "mail_feedback", event_ref: "evt-#{index}")
            assert_equal reason, record.reason
          end

          assert_equal 5, SUPPRESSION.where(organization: @organization, provider: "smtp").count
        end

        test "a temporary failure suppresses and then stops suppressing by itself" do
          record = stop!(reason: "temporary_failure", occurred_at: 1.hour.ago)
          assert record.blocking?

          assert_not record.blocking?(Time.current + SUPPRESSION::SELF_EXPIRY)
          assert record.active?, "ageing out of blocking is not the same as being resolved"
        end

        test "a hard bounce never ages out on its own" do
          record = stop!(reason: "hard_bounce", occurred_at: 5.years.ago)

          assert record.blocking?(10.years.from_now)
        end

        test "a temporary failure that turns out to be a hard bounce stops being self-expiring" do
          stop!(reason: "temporary_failure", event_ref: "evt-soft")
          stop!(reason: "hard_bounce", event_ref: "evt-hard")

          record = SUPPRESSION.active_for(organization: @organization, provider: "infobip",
                                          channel: "viber", destination_digest: digest(PHONE))
          assert_equal "hard_bounce", record.reason
          assert_equal 1, SUPPRESSION.where(organization: @organization).count
        end

        # ---- duplicates and late events -------------------------------------

        test "a redelivered provider event is idempotent" do
          2.times { stop!(event_ref: "evt-1") }

          assert_equal 1, SUPPRESSION.where(organization: @organization).count
        end

        test "an event that arrives after a reactivation is recorded but does not re-suppress" do
          record = stop!(event_ref: "evt-old-1", occurred_at: 3.hours.ago)
          STORE.reactivate!(record, evidence: "inbound_start:99")
          assert_not blocking?

          stop!(event_ref: "evt-old-2", occurred_at: 4.hours.ago)

          assert_not blocking?, "a refusal from before the citizen came back must not drop them again"
          assert_equal 2, SUPPRESSION.where(organization: @organization).count, "and it is still recorded"
        end

        test "a fresh event after a reactivation suppresses again, with a new version" do
          record = stop!(event_ref: "evt-a", occurred_at: 3.hours.ago)
          STORE.reactivate!(record, evidence: "inbound_start:99")

          fresh = stop!(event_ref: "evt-b", occurred_at: Time.current)

          assert blocking?
          assert_equal 2, fresh.address_version
        end

        # ---- reactivation is deliberate and evidenced ------------------------

        test "only a supported reactivation workflow lifts a suppression, and it needs evidence" do
          record = stop!

          assert_raises(ArgumentError) { STORE.reactivate!(record, evidence: "  ") }
          assert blocking?

          STORE.reactivate!(record, evidence: "operator_case:42")

          assert_not blocking?
          assert_equal "operator_case:42", record.reload.reactivation_evidence
          assert_equal "provider_opt_out", record.reason, "the original reason stays readable"
        end

        test "an ordinary topic enable does not clear a provider suppression" do
          stop!
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic: :community_news, channel: :viber, enabled: true)

          assert blocking?, "a grid save changes a preference; it does not speak for the transport"
          assert Decidim::Bih::NotificationPreferences.permitted?(@citizen, topic: :community_news, channel: :viber),
                 "and the preference genuinely did change — the two stores are independent"
        end

        # ---- the webhook path ------------------------------------------------

        test "a provider STOP writes only the destination suppression and preserves topics" do
          Decidim::Bih::Config.stub(:infobip, Decidim::Bih::Config.infobip.merge(viber_bm_sender: "MI")) do
            Decidim::Bih::VerifiedPhone.stub(:delivery_phone_for, PHONE) do
              Decidim::Bih::CitizenPhoneRecord.create!(organization: @organization, user: @citizen,
                                                       phone: PHONE, verified_at: Time.current)
              Decidim::Bih::NotificationPreferences.opt_out_sender!(
                organization: @organization, channel: "viber", sender: PHONE, business_sender: "MI"
              )
            end
          end

          assert blocking?
          assert Decidim::Bih::TopicPreferences.enabled?(@citizen, topic: :community_news)
        end

        test "a STOP from a sender no account matches still records the refusal" do
          Decidim::Bih::Config.stub(:infobip, Decidim::Bih::Config.infobip.merge(viber_bm_sender: "MI")) do
            changed = Decidim::Bih::NotificationPreferences.opt_out_sender!(
              organization: @organization, channel: "viber", sender: "+38765999999", business_sender: "MI"
            )
            assert_not changed, "no preference changed, and the reply text depends on that"
          end

          assert blocking?(value: "+38765999999"), "but the destination still refused"
        end

        test "an opaque chat identity is suppressed as an identity, never parsed as a phone" do
          Decidim::Bih::Config.stub(:infobip, Decidim::Bih::Config.infobip.merge(messenger_sender: "MIPAGE")) do
            Decidim::Bih::NotificationPreferences.opt_out_sender!(
              organization: @organization, channel: "messenger", sender: "1234567890", business_sender: "MIPAGE"
            )
          end

          record = SUPPRESSION.find_by(organization: @organization, channel: "messenger")
          assert_equal "channel_identity", record.destination_kind
          assert_equal KEY.digest(kind: :channel_identity, value: "1234567890"), record.destination_digest
          assert_not blocking?(value: "1234567890", channel: "viber"),
                     "a Messenger id must never be able to silence a handset"
        end

        # ---- mail ingestion is not pretended ---------------------------------

        test "the mail feedback adapter says it is unwired rather than claiming coverage" do
          assert_not Decidim::Bih::Messaging::MailFeedback.configured?

          assert_raises(Decidim::Bih::Messaging::MailFeedback::FeedbackNotConfigured) do
            Decidim::Bih::Messaging::MailFeedback.ingest!(payload: {}, organization: @organization)
          end
        end

        test "the unwired mail adapter is not a silent no-op that reads like coverage" do
          assert_raises(Decidim::Bih::Messaging::TransportSuppression::FeedbackNotConfigured) do
            Decidim::Bih::Messaging::MailFeedback.ingest!(payload: { "recipient" => "recipient@example.invalid" },
                                                          organization: @organization)
          end
          assert_equal 0, SUPPRESSION.where(organization: @organization, provider: "mailbox").count
        end

        # ---- the pre-send recheck -------------------------------------------

        test "all routing modes refuse a suppressed destination at the final recheck" do
          stop!
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic: :report_updates, channel: :viber, enabled: true)
          context = { destination_present: true, destination_digest: digest(PHONE) }
          decide = lambda do |mode|
            Decidim::Bih::Messaging::Policy.decide(
              organization: @organization, message_class: "report.author_external_copy", channel: "viber",
              recipient: Decidim::Bih::Messaging::RecipientContext.account(organization_id: @organization.id,
                                                                           account_id: @citizen.id),
              context:, mode:
            )
          end

          assert_includes decide.call("target").reason_codes, :transport_suppressed
          assert_includes decide.call("compatibility").reason_codes, :transport_suppressed
          assert_includes decide.call("legacy").reason_codes, :transport_suppressed
        end
      end
    end
  end
end
