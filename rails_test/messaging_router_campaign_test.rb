# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Campaign messages use the platform-news topic and one automatic
      # external-delivery intent. P11 remains a hand-addressed email boundary.
      class MessagingRouterCampaignTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        SAMPLE = {
          ime: "Milica", kod: "MI-4821", link: "https://mi.fondacijabijeljina.com/v/AbCdEfGhIjKlMnOp",
          broj: "150", datum: "11.9.", komsiluk: "Brčanska malta", mjesto: "3.",
          grad_lista: "1. Dašnica, 2. Centar", selo_lista: "1. Janja, 2. Dvorovi", fali: "5", ostalo: "12"
        }.freeze

        # Read out of the registry rather than restated: every row here has to
        # be true of `MessageClass`, and the per-key test proves it.
        TRANSACTIONAL = "campaign.transactional_phone"
        MARKETING = "campaign.marketing_phone"
        LETTER = "campaign.letter_p11"

        CONTRACT = {
          "p1" => { message_class: TRANSACTIONAL, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p3" => { message_class: TRANSACTIONAL, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p7" => { message_class: TRANSACTIONAL, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p4" => { message_class: MARKETING, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p5" => { message_class: MARKETING, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p8" => { message_class: MARKETING, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p9" => { message_class: MARKETING, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p10" => { message_class: MARKETING, channels: %w(email messenger instagram viber whatsapp), email_fallback: true, permission: :platform_news },
          "p11" => { message_class: LETTER, channels: [], email_fallback: false, permission: :none }
        }.freeze

        def registry = Decidim::Bih::Messaging::MessageClass

        def routing = Decidim::Bih::Messaging::ExternalCopyRouting

        def enrollment = Decidim::Bih::Messaging::Enrollment

        def templates = Decidim::Bih::Launch::MessageTemplates

        def dispatcher_class = Decidim::Bih::Launch::MessageDispatcher

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
          ActionMailer::Base.deliveries.clear
          @calls = []
          calls = @calls
          @client = Object.new
          @client.define_singleton_method(:configured?) { true }
          @client.define_singleton_method(:viber_business_configured?) { true }
          @client.define_singleton_method(:chat_channel_configured?) { |_channel| false }
          @client.define_singleton_method(:send_phone_message) do |**kw|
            calls << kw
            { "messages" => [{ "messageId" => "campaign-#{calls.length}" }] }
          end
        end

        def enroll!(message_class, mode = "compatibility")
          Decidim::Bih::Setting.put(@organization, Decidim::Bih::Messaging::Modes::NAMESPACE,
                                    "mode.#{message_class}", mode)
        end

        def with_phone(user = @user)
          phone = format("+3876%07d", user.id)
          Decidim::Authorization.find_or_create_by!(user:, name: "sms") do |grant|
            grant.unique_id = Decidim::Bih::SmsAuthorization.unique_id_for(phone)
            grant.granted_at = Time.current
          end
          Decidim::Bih::CitizenPhone.store!(user, phone)
          Decidim::Bih::Infobip::Client.stub(:new, @client) { yield }
        end

        def consent_to_community_news(user = @user, channels: %w(viber whatsapp))
          channels.each do |channel|
            Decidim::Bih::NotificationPreferences.set!(user, topic: :community_news, channel:, enabled: true)
          end
        end

        def suppress_email
          Decidim::Bih::Messaging::TransportSuppression.ingest!(
            organization: @organization, provider: "smtp", channel: "email",
            destination: { kind: "email", value: @user.email }, reason: "hard_bounce", source: "provider_webhook", user: @user
          )
        end

        def dispatcher(user: @user)
          dispatcher_class.new(user, organization: @organization)
        end

        # ---- each key's declared contract --------------------------------------

        CONTRACT.each do |key, expected|
          test "campaign #{key} keeps its channel contract in the registry that owns it" do
            entry = registry.fetch(expected[:message_class])
            channels = entry.channel_groups.flat_map { |group| Array(group[:channels]) }

            assert_includes entry.message_keys, key.upcase, "#{key} must be owned by #{expected[:message_class]}"
            assert_equal expected[:channels].sort, channels.sort
            refute_includes channels, "sms", "no campaign message has an SMS variant"
            assert_equal expected[:email_fallback], channels.include?("email")
          end
        end

        test "the campaign has exactly nine keys and P2 and P6 are not among them" do
          assert_equal %w(p1 p3 p4 p5 p7 p8 p9 p10 p11), templates::KEYS
          assert_equal CONTRACT.keys.sort, templates::KEYS.sort
          owned = [TRANSACTIONAL, MARKETING, LETTER].flat_map { |key| registry.fetch(key).message_keys }

          assert_equal templates::KEYS.map(&:upcase).sort, owned.sort
          refute_includes owned, "P2"
          refute_includes owned, "P6"
        end

        test "MARKETING_KEYS and the registry describe the same split" do
          assert_equal dispatcher_class::MARKETING_KEYS.sort,
                       registry.fetch(MARKETING).message_keys.map(&:downcase).sort
          assert_equal (templates::KEYS - dispatcher_class::MARKETING_KEYS - %w(p11)).sort,
                       registry.fetch(TRANSACTIONAL).message_keys.map(&:downcase).sort
        end

        test "only the WhatsApp-templated marketing keys carry a template, and P11 carries no phone variant" do
          assert_equal %w(p10 p4 p5 p9), templates::WHATSAPP.keys.sort
          refute templates.variant?("p8", :whatsapp), "P8 awaits an approved replacement provider template"
          assert_nil templates.whatsapp_template("p8", **SAMPLE)
          refute templates.variant?("p11", :viber), "P11 is the hand-addressed letter and has no phone variant"
          assert templates.variant?("p11", :email)
        end

        # ---- the routed plan, in compatibility mode ----------------------------

        test "a consented marketing citizen routes to viber and whatsapp and to nothing else" do
          enroll!(MARKETING)
          consent_to_community_news
          with_phone do
            channels = routing.decide(user: @user, organization: @organization, message_class: MARKETING,
                                      requested_channels: %w(viber whatsapp), dedup_key: "launch:p9").channels

            assert_equal %w(viber whatsapp), channels
            refute_includes channels, "sms"
            refute_includes channels, "email"
          end
        end

        test "a disabled platform topic produces no campaign channel" do
          enroll!(MARKETING)
          Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
          with_phone do
            assert_empty routing.decide(user: @user, organization: @organization, message_class: MARKETING,
                                        requested_channels: %w(viber whatsapp), dedup_key: "launch:p4").channels
          end
        end

        test "the marketing class includes email in its one automatic delivery group" do
          %w(legacy compatibility target).each do |mode|
            enroll!(MARKETING, mode)
            entry = registry.fetch(MARKETING)

            assert_equal "external_copy", entry.group_for("email")[:name]
          end
        end

        # ---- behaviour through the real dispatcher -----------------------------

        test "an eligible phone is chosen when email is suppressed" do
          suppress_email
          enroll!(MARKETING)
          consent_to_community_news
          with_phone { assert_equal :phone, dispatcher.deliver("p9", **SAMPLE) }

          assert_equal 1, @calls.size
          refute @calls.sole[:final_sms], "the campaign never falls through to a paid SMS"
          assert_equal [:viber], @calls.sole[:channels]
          assert_empty ActionMailer::Base.deliveries
        end

        test "a disabled platform topic prevents all marketing delivery" do
          enroll!(MARKETING)
          Decidim::Bih::TopicPreferences.set!(@user, topic: :platform_news, enabled: false)
          result = nil
          assert_no_difference "Decidim::Bih::AccountNotification.count" do
            with_phone { result = dispatcher.deliver("p4", **SAMPLE) }
          end

          assert_equal :undeliverable, result
          assert_empty @calls
          assert_empty ActionMailer::Base.deliveries,
                       "deliver_marketing returns :undeliverable and never reaches deliver_email — manifest row T4"
        end

        test "an interrupted enrolled run does not bill a citizen twice" do
          suppress_email
          enroll!(MARKETING)
          consent_to_community_news
          first = second = nil
          with_phone do
            first = dispatcher.deliver("p4", **SAMPLE)
            second = dispatcher.deliver("p4", **SAMPLE)
          end

          assert_equal 1, Decidim::Bih::AccountNotification.where(user: @user, topic: "platform_news").count
          assert_equal 1, @calls.size, "the second run must not be a second paid message"
          assert_equal first, second
        end

        test "a transactional key also chooses an eligible phone when email is suppressed" do
          suppress_email
          enroll!(TRANSACTIONAL)
          with_phone { assert_equal :phone, dispatcher.deliver("p1", **SAMPLE) }

          assert_equal 1, @calls.size
          refute @calls.sole[:final_sms]
          assert_empty ActionMailer::Base.deliveries
        end

        test "an enrolled transactional key chooses proven email without a phone and sends once" do
          enroll!(TRANSACTIONAL, "target")
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@user)
          Decidim::Bih::Infobip::Client.stub(:new, @client) do
            assert_equal :email, dispatcher.deliver("p1", **SAMPLE)
            assert_equal :email, dispatcher.deliver("p1", **SAMPLE)
          end
          assert_equal 1, ActionMailer::Base.deliveries.size
          assert_empty @calls
        end

        # ---- P11: preserved, not fixed -----------------------------------------

        test "P11 can never be routed however the flag is set" do
          enroll!(LETTER, "target")

          refute registry.fetch(LETTER).enrolled?
          assert registry.fetch(LETTER).external_boundary?
          refute enrollment.routes?(organization: @organization, message_class: LETTER)
          assert_equal :legacy, enrollment.mode(organization: @organization, message_class: LETTER)
        end

        test "P11 has no platform audience and keeps its hand-addressed e-mail exactly as today" do
          enroll!(LETTER, "target")
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@user)

          assert_empty Decidim::Bih::Launch::CampaignRecipients.for(organization: @organization, key: "p11")
          result = with_phone do
            perform_enqueued_jobs(only: Decidim::Bih::Launch::InvitationDeliveryJob) { dispatcher.deliver("p11", **SAMPLE) }
          end

          assert_equal :email, result
          assert_empty @calls, "P11 has no phone variant"
        end

        # ---- the reward invitation is a different thing -------------------------

        test "the launch invitation is NOT a campaign message and keeps SMS plus its e-mail fallback" do
          phone = registry.fetch("goodwill.launch_invitation_phone")
          email = registry.fetch("goodwill.launch_invitation_email")

          assert_includes phone.channel_groups.flat_map { |group| Array(group[:channels]) }, "sms"
          assert_equal %w(email), (email.channel_groups.flat_map { |group| Array(group[:channels]) })
          assert_equal "account_lifecycle", phone.payload_class
          assert_equal "account_lifecycle", email.payload_class
          refute_equal "marketing", phone.payload_class, "an invitation is a reward fulfilment, not marketing"
        end

        test "neither invitation class is enrolled, so no campaign flag can move them" do
          %w(goodwill.launch_invitation_phone goodwill.launch_invitation_email).each do |key|
            enroll!(key, "target")

            refute registry.fetch(key).enrolled?, "#{key} must stay on its legacy body"
            refute enrollment.routes?(organization: @organization, message_class: key)
          end
        end

        test "no campaign class carries SMS and no invitation class carries a marketing payload" do
          [TRANSACTIONAL, MARKETING, LETTER].each do |key|
            entry = registry.fetch(key)
            channels = entry.channel_groups.flat_map { |group| Array(group[:channels]) }

            refute_includes channels, "sms", "#{key} must never be billed per segment"
          end
        end
      end
    end
  end
end
