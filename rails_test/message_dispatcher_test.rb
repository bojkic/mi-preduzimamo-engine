# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # All campaign deliveries honor platform-news choice and choose one
      # eligible transport. Provider acceptance and uncertain attempts are
      # tested separately; P11 keeps its dedicated email variant.
      class MessageDispatcherTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        SAMPLE = {
          ime: "Milica",
          kod: "MI-4821",
          link: "https://mi.fondacijabijeljina.com/v/AbCdEfGhIjKlMnOp",
          broj: "150",
          datum: "11.9.",
          komsiluk: "Brčanska malta",
          mjesto: "3.",
          grad_lista: "1. Dašnica, 2. Centar",
          selo_lista: "1. Janja, 2. Dvorovi"
        }.freeze

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          ActionMailer::Base.deliveries.clear
          @calls = []
          @client = Object.new
          calls = @calls
          @client.define_singleton_method(:configured?) { true }
          @client.define_singleton_method(:viber_business_configured?) { true }
          @client.define_singleton_method(:chat_channel_configured?) { |_channel| false }
          @client.define_singleton_method(:send_phone_message) do |**kw|
            calls << kw
            { "messages" => [{ "messageId" => "campaign-test-#{calls.length}" }] }
          end
        end

        def dispatcher(user: @user)
          Decidim::Bih::Launch::MessageDispatcher.new(user, organization: @organization)
        end

        def with_phone
          Decidim::Authorization.find_or_create_by!(user: @user, name: "sms") do |grant|
            grant.unique_id = Decidim::Bih::SmsAuthorization.unique_id_for("+38765111222")
            grant.granted_at = Time.current
          end
          Decidim::Bih::CitizenPhone.store!(@user, "+38765111222")
          Decidim::Bih::Infobip::Client.stub(:new, @client) { yield }
        end

        def consent_to_community_news
          %w(viber whatsapp).each do |channel|
            Decidim::Bih::NotificationPreferences.set!(@user, topic: :community_news, channel:, enabled: true)
          end
        end

        def suppress_email
          Decidim::Bih::Messaging::TransportSuppression.ingest!(
            organization: @organization, provider: "smtp", channel: "email",
            destination: { kind: "email", value: @user.email }, reason: "hard_bounce", source: "provider_webhook", user: @user
          )
        end

        def with_env(values)
          original = values.keys.index_with { |key| ENV.fetch(key, nil) }
          values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Decidim::Bih::Config.reset!
          yield
        ensure
          original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Decidim::Bih::Config.reset!
        end

        test "a citizen with a phone gets P1 through the phone chain, never by SMS and never by e-mail" do
          suppress_email
          with_phone { assert_equal :phone, dispatcher.deliver("p1", **SAMPLE) }

          call = @calls.sole

          assert_equal "+38765111222", call[:to]
          assert_equal Decidim::Bih::Launch::MessageTemplates.render("p1", channel: :viber, **SAMPLE), call[:text]
          refute call[:final_sms], "the campaign never falls through to a paid SMS"
          assert_nil call[:whatsapp_template], "P1 carries the reservation number and has no WhatsApp template"
          assert_empty ActionMailer::Base.deliveries
        end

        test "consented marketing uses the shared phone intent without a final SMS" do
          suppress_email
          consent_to_community_news
          with_phone { assert_equal :phone, dispatcher.deliver("p9", **SAMPLE) }

          call = @calls.sole
          refute call[:final_sms]
          assert_equal Decidim::Bih::Launch::MessageTemplates.render("p9", channel: :viber, **SAMPLE), call[:text]
          assert_equal [:viber], call[:channels]
        end

        test "consented marketing attaches its enabled approved WhatsApp template" do
          suppress_email
          consent_to_community_news
          with_env("INFOBIP_WHATSAPP_SENDER" => "38766900003", "INFOBIP_WHATSAPP_CAMPAIGN_TEMPLATES_ENABLED" => "1",
                   "INFOBIP_MESSAGES_API_ENABLED" => "1") do
            with_phone { assert_equal :phone, dispatcher.deliver("p9", **SAMPLE) }
          end
          template = @calls.sole.fetch(:whatsapp_template)
          assert_equal "mi_p9_trka_sedmica_v1", template[:name]
          assert_equal "sr", template[:language]
          assert_equal({ "1" => "11.9.", "2" => "Brčanska malta", "3" => "3.", "4" => "150",
                         "5" => "1. Dašnica, 2. Centar", "6" => "1. Janja, 2. Dvorovi" }, template[:body].stringify_keys)
          assert_equal [:viber, :whatsapp], @calls.sole[:channels]
        end

        test "a fresh marketing intent omits disabled campaign templates" do
          suppress_email
          consent_to_community_news
          with_env("INFOBIP_WHATSAPP_SENDER" => "38766900003", "INFOBIP_WHATSAPP_CAMPAIGN_TEMPLATES_ENABLED" => nil,
                   "INFOBIP_MESSAGES_API_ENABLED" => "1") do
            with_phone { assert_equal :phone, dispatcher.deliver("p9", **SAMPLE) }
          end
          assert_nil @calls.sole[:whatsapp_template]
          assert_equal [:viber], @calls.sole[:channels]
        end

        test "a disabled platform topic prevents marketing through every channel" do
          Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
          assert_no_difference("Decidim::Bih::AccountNotification.count") do
            with_phone { assert_equal :undeliverable, dispatcher.deliver("p9", **SAMPLE) }
          end
          assert_empty @calls
          assert_empty ActionMailer::Base.deliveries
        end

        test "falls back to email, reusing the Viber-formatted text, when no phone is on file" do
          result = perform_enqueued_jobs(only: Decidim::Bih::Launch::InvitationDeliveryJob) { dispatcher.deliver("p1", **SAMPLE) }

          assert_equal :email, result
          assert_equal 1, ActionMailer::Base.deliveries.size
          mail = ActionMailer::Base.deliveries.first
          assert_equal [@user.email], mail.to
          assert_equal I18n.t("decidim.bih.communication_settings.topics.platform_news", locale: :sr), mail.subject
          assert_match(/čćžšđ|Aktivista/, mail.body.decoded)
        end

        test "P11 is delivered by email using its own dedicated subject and variant, even with a phone on file" do
          result = with_phone do
            perform_enqueued_jobs(only: Decidim::Bih::Launch::InvitationDeliveryJob) { dispatcher.deliver("p11", **SAMPLE) }
          end

          assert_equal :email, result
          assert_empty @calls, "P11 has no phone variant"
          mail = ActionMailer::Base.deliveries.first
          assert_equal I18n.t("decidim.bih.launch.messages.p11.email_subject", locale: :sr), mail.subject
          assert_match(/mjesne zajednice/i, mail.body.decoded)
        end

        test "an uncertain provider attempt is not retried or followed by another channel" do
          suppress_email
          calls = @calls
          @client.define_singleton_method(:send_phone_message) do |**kw|
            calls << kw
            raise Decidim::Bih::Infobip::Error, "connection lost"
          end
          with_phone do
            assert_equal :undeliverable, dispatcher.deliver("p1", **SAMPLE)
            assert_equal :undeliverable, dispatcher.deliver("p1", **SAMPLE)
          end
          assert_equal 1, @calls.size
          assert_empty ActionMailer::Base.deliveries
          assert_equal "unknown", Decidim::Bih::AccountNotification.where(user: @user).sole.status
        end

        # P11 is the letter to MZ presidents: e-mail only, no phone variant at
        # all. A citizen with a phone but no e-mail address therefore has no route
        # for it.
        test "a message with no phone variant is undeliverable without an e-mail address" do
          @user.email = ""

          result = perform_enqueued_jobs(only: Decidim::Bih::Launch::InvitationDeliveryJob) { dispatcher.deliver("p11", **SAMPLE) }

          assert_equal :undeliverable, result
          assert_empty ActionMailer::Base.deliveries
        end

        test "never raises and sends nothing when no route is available" do
          @user.email = ""

          result = nil
          assert_nothing_raised do
            result = perform_enqueued_jobs(only: Decidim::Bih::Launch::InvitationDeliveryJob) { dispatcher.deliver("p1", **SAMPLE) }
          end

          assert_equal :undeliverable, result
          assert_empty ActionMailer::Base.deliveries
        end
      end
    end
  end
end
