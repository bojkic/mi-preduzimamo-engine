# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class MagicLinkConsumeOrderTest < ActionDispatch::IntegrationTest
        PHONE = "+38765123456"

        setup do
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          # The onboarding chain starts at the :sms verification form, which
          # only a phone-first host registers, so CompletesPhoneAuthentication
          # asks NextStep only when the switch is on. This is that host.
          Decidim::Bih.phone_first_registration = true
        end

        teardown { Decidim::Bih.phone_first_registration = false }

        # The generated harness host runs with short magic links OFF
        # (SHORT_MAGIC_LINKS defaults to 0 in script/decidim_bih_rails_test), so
        # the literal "/v/:token" host route does not exist there. Ask
        # Decidim::Bih for the path the running configuration actually emits —
        # short root path or engine-mounted — exactly as the SMS/Viber sender does.
        def consume_path(raw) = Decidim::Bih.magic_link_path(raw)

        def pending!(phone: PHONE)
          Decidim::Authorization.create!(
            user: @citizen, name: "sms", unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current }, granted_at: nil
          )
        end

        # A citizen who only ever proved an address: pending postal_letter,
        # NO sms authorization at all. This is the shape that makes routing a
        # postal link through NextStep wrong.
        def pending_postal!
          Decidim::Authorization.create!(
            user: @citizen, name: "postal_letter", unique_id: "postal-#{@citizen.id}",
            verification_metadata: {
              "address" => "Karađorđeva 1, Bijeljina", "verification_code" => "654321",
              "letter_sent_at" => Time.current
            },
            granted_at: nil
          )
        end

        # Compare destinations by PATH: the route helpers carry the test
        # session's default_url_options (?locale=en) while a real redirect does
        # not, and the query string is not what these assertions are about.
        def path_of(url) = URI.parse(url.to_s).path

        # Warden's session entry is [[user_id], authenticatable_salt]; the id is
        # the part worth asserting. nil means no session was ever opened.
        def signed_in_user_id = session["warden.user.user.key"]&.first&.first

        # Swap Rails.logger for a StringIO sink for the duration of the block
        # and hand back everything written to it.
        def captured_log
          io = StringIO.new
          previous = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(io)
          yield
          io.string
        ensure
          Rails.logger = previous
        end

        test "a verify link whose grant fails does not sign the citizen in" do
          pending!(phone: "+38765000000") # token phone will not match
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "verify", phone: PHONE)

          log = captured_log { post consume_path(raw) }

          assert_response :unprocessable_entity
          assert_nil signed_in_user_id, "no session is opened for a refused link"
          refute Decidim::Authorization.find_by(user: @citizen, name: "sms").granted?,
                 "a refused link never grants the authorization"

          # The refusal is diagnosable — user id and reason — and carries no
          # part of the number the citizen typed.
          assert_includes log, "[decidim-bih] verify link refused for user #{@citizen.id}: phone_mismatch"
          refute_includes log, PHONE, "the refusal log never carries the phone"
          refute_includes log, "65000000", "nor the number the authorization was bound to"

          get Decidim::Bih.public_path("moj-nalog")
          assert_equal path_of(decidim.new_user_session_path), path_of(response.location),
                       "still anonymous: the account page bounces to sign-in"
        end

        test "a verify link that grants signs in and continues to the komsiluk picker" do
          pending!
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "verify", phone: PHONE)

          post consume_path(raw)

          # app=1 is the PWA install marker CompletesPhoneAuthentication adds to
          # every finished verification, on the device that just proved a phone.
          assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1"
          assert Decidim::Authorization.find_by(user: @citizen, name: "sms").granted?
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "a postal link signs the citizen in and never sends them to the phone form" do
          pending_postal!
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "postal")

          post consume_path(raw)

          assert_redirected_to "#{Decidim::Bih.public_path("moj-nalog")}#zavrsi-nalog"
          refute_equal Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr), path_of(response.location),
                       "an address proof must never be answered with the SMS phone form"
          assert_equal @citizen.id, signed_in_user_id, "the postal citizen is signed in"
          assert Decidim::Authorization.find_by(user: @citizen, name: "postal_letter").granted?
          assert_nil Decidim::Authorization.find_by(user: @citizen, name: "sms"),
                     "a postal proof never invents an sms authorization"
        end
      end
    end
  end
end
