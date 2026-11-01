# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The campaign used to be a Rails-console loop: no record of who had
      # been reached, so a run that died halfway and was restarted sent to
      # everyone again, on a paid channel, to the whole base — and no ceiling,
      # no dry run, no audit trail (review 2026-09-07, lane 6 H1).
      class LaunchCampaignSendTest < ActiveSupport::TestCase
        SAMPLE = {
          ime: "Milica",
          broj: "150",
          link: "https://mi.fondacijabijeljina.com/biceriseno/zajednistvo?tab=trka",
          datum: "11.9.",
          komsiluk: "Brčanska malta",
          mjesto: "3.",
          grad_lista: "1. Dašnica, 2. Centar",
          selo_lista: "1. Janja, 2. Dvorovi"
        }.freeze

        setup do
          travel_to Time.utc(2026, 9, 27, 12)
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: @citizen, name: "sms", granted_at: Time.current,
                                         unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+38765111222"))
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765111222")
          Decidim::Bih::NotificationPreferences.set!(@citizen, topic: :community_news, channel: :viber, enabled: true)
          Decidim::Bih::Messaging::TransportSuppression.ingest!(
            organization: @organization, provider: "smtp", channel: "email",
            destination: { kind: "email", value: @citizen.email }, reason: "hard_bounce", source: "provider_webhook", user: @citizen
          )
          @calls = []
          calls = @calls
          @client = Object.new
          @client.define_singleton_method(:configured?) { true }
          @client.define_singleton_method(:viber_business_configured?) { true }
          @client.define_singleton_method(:chat_channel_configured?) { |_channel| false }
          @client.define_singleton_method(:send_phone_message) do |**kwargs|
            calls << kwargs
            { "messages" => [{ "messageId" => "campaign-test-#{calls.length}" }] }
          end
        end

        teardown { travel_back }

        def send_campaign(**options)
          Decidim::Bih::Infobip::Client.stub(:new, @client) do
            Decidim::Bih::Launch::CampaignSend.new(
              organization: @organization, key: "p8", recipients: [@citizen], vars: SAMPLE, **options
            ).call
          end
        end

        test "a dry run counts the recipients and sends nothing" do
          result = send_campaign

          assert_equal({ sent: 0, skipped: 0, undeliverable: 0, dry_run: true, would_send: 1 }, result)
          assert_empty @calls, "a dry run must never reach the provider"
          assert_equal 0, audit_events.count
        end

        test "a live run sends once and records who was reached" do
          result = send_campaign(dry_run: false)

          assert_equal 1, result[:sent]
          assert_equal 1, @calls.size
          assert_equal 1, audit_events.count

          event = audit_events.first

          assert_equal "p8", event.metadata["message_key"]
          assert_equal @citizen.id, event.metadata["user_id"]
          assert_equal "phone", event.metadata["channel"]
          refute event.metadata.has_key?("phone"), "the number must never reach the audit row"
        end

        test "an explicit platform-topic refusal prevents campaign sends" do
          Decidim::Bih::TopicPreferences.set!(@citizen, topic: :platform_news, enabled: false)

          assert_no_difference("Decidim::Bih::AccountNotification.count") do
            result = send_campaign(dry_run: false)
            assert_equal({ sent: 0, skipped: 0, undeliverable: 1, dry_run: false }, result)
          end
          assert_empty @calls
          assert_equal 0, audit_events.count
        end

        # The whole point of the ledger: an interrupted run is restarted, and
        # everyone already reached is skipped rather than billed twice.
        test "a re-run sends nothing to a citizen already reached" do
          send_campaign(dry_run: false)
          result = send_campaign(dry_run: false)

          assert_equal({ sent: 0, skipped: 1, undeliverable: 0, dry_run: false }, result)
          assert_equal 1, @calls.size, "the second run must not reach the provider again"
          assert_equal 1, audit_events.count
        end

        # The dry run's job is to say "safe to send". A variable the operator
        # forgot is a typo in their command, and it must surface here rather than
        # aborting a live run partway through a paid batch.
        test "a dry run names a missing message variable instead of reporting success" do
          error = assert_raises(ArgumentError) do
            Decidim::Bih::Launch::CampaignSend.new(
              organization: @organization, key: "p8", recipients: [@citizen], vars: SAMPLE.except(:link)
            ).call
          end

          assert_match(/p8 needs link/, error.message)
        end

        test "the ceiling refuses an oversized batch before anything is sent" do
          others = 2.times.map do
            user = FactoryBot.create(:user, :confirmed, organization: @organization)
            Decidim::Bih::CitizenPhone.store!(user, "+3876511122#{user.id % 10}")
            user
          end

          error = assert_raises(Decidim::Bih::Launch::CampaignSend::CeilingExceeded) do
            Decidim::Bih::Infobip::Client.stub(:new, @client) do
              Decidim::Bih::Launch::CampaignSend.new(
                organization: @organization, key: "p8", recipients: [@citizen] + others,
                dry_run: false, max_recipients: 2, vars: SAMPLE
              ).call
            end
          end

          assert_match(/exceed MAX_RECIPIENTS=2/, error.message)
          assert_empty @calls, "the ceiling refuses the batch, it does not send half of it"
        end

        test "an unknown message key is refused" do
          assert_raises(ArgumentError) do
            Decidim::Bih::Launch::CampaignSend.new(
              organization: @organization, key: "p2", recipients: [@citizen]
            ).call
          end
        end

        # P4 is for citizens still short of the threshold; P8/P9/P10 are for
        # everyone with a number. Blasting every message at the whole base is
        # what made the campaign the largest line in the cost model.
        test "recipient scopes are narrowed per message" do
          assert_includes Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p8"),
                          @citizen
          assert_includes Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p4"),
                          @citizen, "a citizen with no invitation is exactly who P4 is for"
          assert_empty Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p1"),
                       "P1 goes to invitation holders, and this citizen has none"
          assert_empty Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p11")
          assert_raises(ArgumentError) do
            Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p2")
          end
        end

        # A citizen with no stored number cannot be addressed on Viber or
        # WhatsApp, and the campaign has no SMS leg to fall back to.
        test "a citizen without a stored phone is not in any phone scope" do
          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)

          refute_includes Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p8"),
                          stranger
        end

        test "every recipient is validated before the first provider call" do
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          vars = ->(user) { user == @citizen ? SAMPLE : SAMPLE.except(:link) }
          assert_raises(ArgumentError) do
            Decidim::Bih::Infobip::Client.stub(:new, @client) do
              Decidim::Bih::Launch::CampaignSend.new(organization: @organization, key: "p8",
                recipients: [@citizen, other], vars:, dry_run: false).call
            end
          end
          assert_empty @calls
          assert_empty audit_events
        end

        test "weekly editions isolate both send audit and delivery deduplication" do
          builder = Object.new
          builder.define_singleton_method(:validate_state!) { true }
          builder.define_singleton_method(:call) { |_user| SAMPLE }
          Decidim::Bih::Launch::CampaignVariables.stub(:new, ->(**_attributes) { builder }) do
            Decidim::Bih::Infobip::Client.stub(:new, @client) do
              results = %w(2026-w39 2026-w39 2026-w40).map do |edition|
                Decidim::Bih::Launch::CampaignSend.new(organization: @organization, key: "p9",
                  recipients: [@citizen], edition:, dry_run: false).call
              end
              assert_equal [1,0,1], results.map { |result| result[:sent] }
            end
          end
          assert_equal 2, @calls.size
          assert_equal %w(2026-w39 2026-w40), audit_events.order(:id).map { |event| event.metadata.fetch("edition") }
        end

        test "P8 cannot use the old provider text after local copy changes" do
          refute Decidim::Bih::Launch::MessageTemplates.variant?("p8", :whatsapp)
          assert_nil Decidim::Bih::Launch::MessageTemplates.whatsapp_template("p8", **SAMPLE)
        end

        private

        def audit_events
          Decidim::Bih::OperatorAuditEvent.where(
            organization: @organization,
            event_type: Decidim::Bih::Launch::CampaignSend::EVENT_TYPE
          )
        end
      end
    end
  end
end
