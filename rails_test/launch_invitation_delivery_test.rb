# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class LaunchInvitationDeliveryTest < ActionMailer::TestCase
        Service = Decidim::Bih::Goodwill::LaunchInvitation

        setup do
          # Keep this launch fixture live; individual tests still exercise expiry.
          travel_to Time.zone.local(2026, 9, 15, 12)
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: @citizen, name: "sms",
                                         unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+38765123456"), granted_at: Time.current)
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization, key: Service::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje 17.9." },
            cost: 20, stock: 450, deducts_points: false,
            auto_issue_at_threshold: true,
            expires_at: Time.zone.parse("2026-09-16 23:59:59")
          )
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 50, reason: "test_seed")
          @invitation = Service.issue_for(@citizen)
        end

        test "emails the citizen their entry code" do
          email = Decidim::Bih::Goodwill::LaunchInvitationMailer
                  .invitation(@invitation).deliver_now

          assert_equal [@citizen.email], email.to
          assert_includes email.body.encoded, @invitation.entry_code
          # The code is a door pass, never something the citizen types in; the
          # e-mail has to say so next to the code, and say the button is where the
          # confirming happens.
          assert_includes email.body.decoded,
                          I18n.t("decidim.bih.goodwill.launch_invitation_mailer.invitation.entry_note", locale: :sr)
          assert_includes email.body.decoded, "„Potvrđujem dolazak”"
        end

        test "the e-mail carries the one-tap confirm link when the job delivers it" do
          perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }

          # Not deliveries.last: with no phone on file the job also publishes the
          # waiting-for-phone event, whose notification e-mail lands after this one.
          subject = I18n.t("decidim.bih.goodwill.launch_invitation_mailer.invitation.subject", locale: :sr)
          email = ActionMailer::Base.deliveries.find { |m| m.subject == subject }
          assert email, "the invitation e-mail was delivered"
          assert_match %r{https://#{Regexp.escape(@organization.host)}(?:/[^/\s]+)?/v/[A-Za-z0-9_-]{32}}, email.body.decoded
          token = Decidim::Bih::LoginToken.where(user: @citizen, purpose: "invitation", consumed_at: nil).first
          assert token, "an invitation token is minted for the link"
          assert_in_delta 72.hours.from_now, token.expires_at, 5.minutes
        end

        test "the entry code never reaches the logs" do
          log = StringIO.new
          original = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(log)

          begin
            Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id)
          ensure
            Rails.logger = original
          end

          refute_includes log.string, @invitation.entry_code,
                          "ulazni kod se ne smije pojaviti u logovima"
        end

        test "delivery succeeds when no phone number is stored" do
          assert_nothing_raised do
            Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id)
          end
        end

        test "sending SMS never enqueues a job carrying the raw phone number" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")

          # deliver_phone must send synchronously through Infobip::Client,
          # never via Infobip::SendSmsJob.perform_later(to: phone, ...) — that
          # would serialize the raw number into Redis/Sidekiq (and again on
          # every retry_on attempt) outside decidim_bih_citizen_phones and
          # outside the retention sweep's reach.
          assert_no_enqueued_jobs(only: Decidim::Bih::Infobip::SendSmsJob) do
            Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id)
          end
        end

        # WhatsApp only ever carries the approved template: its placeholder and
        # the confirm token as the button suffix — the same token the SMS link
        # ends with. Without a configured template the keyword is nil and the
        # chain is Viber -> SMS as before.
        test "a configured invitation template reaches the client with the reservation number and the confirm token" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          calls = []
          fake_client = Object.new
          fake_client.define_singleton_method(:configured?) { true }
          fake_client.define_singleton_method(:send_phone_message) do |**kw|
            calls << kw
            { "ok" => true }
          end

          with_env("INFOBIP_WHATSAPP_SENDER" => "38766900003",
                   "INFOBIP_WHATSAPP_INVITATION_TEMPLATE_NAME" => "mi_pozivnica_lansiranje_v1") do
            Decidim::Bih::Infobip::Client.stub(:new, fake_client) do
              perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
            end
          end

          template = calls.sole.fetch(:whatsapp_template)
          assert_equal "mi_pozivnica_lansiranje_v1", template[:name]
          assert_equal "sr", template[:language]
          assert_equal({ "1" => @invitation.entry_code }, template[:body])
          assert_equal calls.sole[:text].split("/").last, template[:button_suffix]
          assert_match(/\A[A-Za-z0-9_-]{32}\z/, template[:button_suffix])
        end

        test "without a configured template the client gets no whatsapp_template" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          calls = []
          fake_client = Object.new
          fake_client.define_singleton_method(:configured?) { true }
          fake_client.define_singleton_method(:send_phone_message) do |**kw|
            calls << kw
            { "ok" => true }
          end

          with_env("INFOBIP_WHATSAPP_INVITATION_TEMPLATE_NAME" => nil) do
            Decidim::Bih::Infobip::Client.stub(:new, fake_client) do
              perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
            end
          end

          assert_nil calls.sole[:whatsapp_template]
        end

        test "a delivered phone message carries viber_text, never otp_code, and sends no e-mail" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          calls = []
          deliveries_were_empty_at_call = nil
          fake_client = Object.new
          fake_client.define_singleton_method(:configured?) { true }
          fake_client.define_singleton_method(:send_phone_message) do |**kw|
            deliveries_were_empty_at_call = ActionMailer::Base.deliveries.empty?
            calls << kw
            { "ok" => true }
          end

          Decidim::Bih::Infobip::Client.stub(:new, fake_client) do
            perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
          end

          assert deliveries_were_empty_at_call, "the phone attempt happens first"
          assert_equal 1, calls.size
          assert_equal "+38765123456", calls.first[:to]
          assert_includes calls.first[:text], @invitation.entry_code
          # The SMS provides an HTTPS confirmation link built from the organization
          # host and tells the citizen the code is shown
          # at the door rather than typed anywhere.
          # The harness host mounts the engine under a prefix and does not enable the
          # short /v/ path, so the link may carry the mount segment before /v/.
          assert_match %r{https://#{Regexp.escape(@organization.host)}(?:/[^/\s]+)?/v/[A-Za-z0-9_-]{32}}, calls.first[:text]
          assert_includes calls.first[:text], "pokazi ga na ulazu"
          assert calls.first[:viber_text].present?, "Viber gets its own (diacritics-preserving) text"
          refute calls.first.has_key?(:otp_code), "an invitation code is not an OTP"
          # E-mail is the fallback, not a duplicate: the address is unproven on a
          # phone-first host and this mail carries the reservation number shown at
          # the door plus a 72-hour bearer confirm link (review 2026-09-07, lane 6
          # H4). The phone message went; nothing else needs to.
          assert_empty ActionMailer::Base.deliveries,
                       "a delivered phone message is the whole delivery"
          # An invitation lives 24 hours, so it waits hours on the free channel
          # rather than falling through to a paid SMS after a minute offline.
          assert_equal Decidim::Bih::Infobip::Client::CAMPAIGN_CHANNEL_VALIDITY.to_i,
                       calls.first[:channel_validity_seconds]
        end

        test "approved invitation SMS stays within one GSM-7 segment on the production host" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          calls = []
          fake_client = Object.new
          fake_client.define_singleton_method(:configured?) { true }
          fake_client.define_singleton_method(:send_phone_message) do |**kw|
            calls << kw
            { "ok" => true }
          end

          original_host = @organization.host
          original_short_magic_links = Decidim::Bih.magic_link_short_path_enabled

          begin
            @organization.update!(host: "mi.fondacijabijeljina.com")
            Decidim::Bih.magic_link_short_path_enabled = true
            Decidim::Bih::Infobip::Client.stub(:new, fake_client) do
              perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
            end
          ensure
            Decidim::Bih.magic_link_short_path_enabled = original_short_magic_links
            @organization.update!(host: original_host)
          end

          sms = calls.sole.fetch(:text)
          assert_match %r{https://mi\.fondacijabijeljina\.com/v/[A-Za-z0-9_-]{32}}, sms
          assert_includes sms, @invitation.entry_code
          assert_includes sms, "pokazi ga na ulazu"
          segments = Decidim::Bih::Sms::SegmentCounter.for(sms)
          assert_equal :gsm7, segments[:encoding]
          assert_equal 1, segments[:segments], "invitation SMS must stay within one segment (#{segments[:characters]} chars)"
        end

        # J1: a transient/unconfigured phone-delivery failure is log-only. A
        # citizen whose phone IS on file already proved it — telling them to
        # "confirm your number" again would be actively wrong, not merely
        # unhelpful, so the waiting-for-phone event must never fire here.
        test "when phone delivery raises, only the e-mail goes out and no waiting-for-phone event is published" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          failing_client = Object.new
          failing_client.define_singleton_method(:configured?) { true }
          failing_client.define_singleton_method(:send_phone_message) { |**_kw| raise Decidim::Bih::Infobip::Error, "boom" }

          log = StringIO.new
          original_logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(log)
          events = []

          begin
            Decidim::Bih::Infobip::Client.stub(:new, failing_client) do
              events = capture_events_manager_publish do
                perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
              end
            end
          ensure
            Rails.logger = original_logger
          end

          assert_empty events, "a transient phone-delivery failure must never surface the waiting-for-phone nudge"
          assert_equal 1, ActionMailer::Base.deliveries.count
          assert_includes log.string, "launch invitation phone delivery failed"
          refute_includes log.string, "+38765123456"
        end

        test "when Infobip is not configured only the e-mail goes out and no event is published" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          unconfigured_client = Object.new
          unconfigured_client.define_singleton_method(:configured?) { false }

          log = StringIO.new
          original_logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(log)
          events = []

          begin
            events = Decidim::Bih::Infobip::Client.stub(:new, unconfigured_client) do
              capture_events_manager_publish do
                perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
              end
            end
          ensure
            Rails.logger = original_logger
          end

          assert_empty events
          assert_equal 1, ActionMailer::Base.deliveries.count
          assert_includes log.string, "not configured"
        end

        test "without a stored phone the e-mail still goes out and the waiting-for-phone event is published" do
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)

          log = StringIO.new
          original_logger = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(log)
          events = []

          begin
            events = capture_events_manager_publish do
              perform_enqueued_jobs { Decidim::Bih::Goodwill::LaunchInvitationDeliveryJob.perform_now(@invitation.id) }
            end
          ensure
            Rails.logger = original_logger
          end

          assert_equal 1, events.size
          assert_equal Decidim::Bih::Goodwill::LaunchInvitationWaitingForPhoneEvent, events.first[:event_class]
          assert_equal 1, ActionMailer::Base.deliveries.count
          # The whole line, not a bare integer: a fulfillment id is one or two
          # digits here and would match a timestamp, a queue name or the code
          # length in any unrelated log line.
          assert_includes log.string,
                          "poruka telefonom nije poslana za fulfillment #{@invitation.id}",
                          "the no-phone path must be identifiable in the log, not merely numerically present"
        end

        private

        # Intercepts Decidim::EventsManager.publish calls (rather than
        # inspecting ActiveJob's enqueued_jobs, whose args serialize the
        # resource as an opaque GlobalID) so a test can pin the EXACT event
        # class a call site published — or assert it published none at all.
        # Does not delegate to the real implementation: these tests only care
        # whether the job's call site fired, not Decidim's downstream
        # mail/notification plumbing.
        def capture_events_manager_publish
          calls = []
          Decidim::EventsManager.stub(:publish, ->(**kwargs) { calls << kwargs }) { yield }
          calls
        end

        private

        def with_env(values)
          original = values.keys.index_with { |key| ENV.fetch(key, nil) }
          values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Decidim::Bih::Config.reset!
          yield
        ensure
          original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
          Decidim::Bih::Config.reset!
        end
      end
    end
  end
end
