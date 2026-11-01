# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The invite link lands on the registration form with ?ref=<nickname>;
      # the code is captured there and spent on the account the form opens.
      class ReferralLinkRegistrationTest < ActionDispatch::IntegrationTest
        PHONE = "+38765123456"

        class SilentGateway
          def initialize(_phone, _code, _context = {}); end

          def deliver_code = true
        end

        # The generated host intentionally has no Redis. Keep the limiter's
        # atomic increment/first-write TTL behavior local to this harness test.
        # Both counters fail closed, so no shared test helper is loaded or weakened.
        class FakeRedis
          def initialize
            @store = {}
            @ttl = {}
          end

          def incr(key) = @store[key] = @store.fetch(key, 0) + 1

          def expire(key, seconds) = @ttl[key] = seconds

          def get(key) = @store[key]&.to_s

          def del(key) = @store.delete(key)

          def eval(_script, keys:, argv:)
            key = keys.first
            value = incr(key)
            expire(key, argv.first) if value == 1
            value
          end
        end

        setup do
          @previous_gateway = Decidim.sms_gateway_service
          @previous_attempt_limiter_redis = Decidim::Bih::RegistrationsController.attempt_limiter_redis
          @previous_phone_first_registration = Decidim::Bih.phone_first_registration
          @registration_state_captured = true

          @organization = create_organization
          host! @organization.host
          @komsiluk = build_komsiluk!(@organization)
          @referrer = FactoryBot.create(:user, :confirmed, organization: @organization, nickname: "ana_poziva")
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih::RegistrationsController.attempt_limiter_redis = FakeRedis.new
          Decidim.sms_gateway_service = SilentGateway.name
        end

        teardown do
          if @registration_state_captured
            Decidim.sms_gateway_service = @previous_gateway
            Decidim::Bih::RegistrationsController.attempt_limiter_redis = @previous_attempt_limiter_redis
            Decidim::Bih.phone_first_registration = @previous_phone_first_registration
          end
        end

        def base = Decidim::Bih.public_path("registracija")

        def registration_params
          {
            user: {
              name: "Mila Gradjanka",
              email: "mila-#{SecureRandom.hex(4)}@example.org",
              mobile_phone_number: PHONE,
              komsiluk_id: @komsiluk.id,
              tos_agreement: "1",
              newsletter: "0"
            }
          }
        end

        test "the share link points at the registration form with the referrer's code" do
          links = Decidim::Bih::Goodwill::InviteLinks.new(@referrer, base_url: "https://#{@organization.host}")
          assert_equal "https://#{@organization.host}#{base}?ref=ana_poziva", links.landing_url
        end

        test "landing on /registracija with ?ref= attributes the registration to the referrer" do
          get "#{base}?ref=ana_poziva"
          assert_response :success

          params = registration_params
          post base, params: params
          assert_response :redirect

          invitee = Decidim::User.find_by(email: params[:user][:email], organization: @organization)
          assert invitee, "the registration opened an account"
          referral = Decidim::Bih::Goodwill::Referral.find_by(invitee_id: invitee.id)
          assert referral, "the referral code from the link was spent on the new account"
          assert_equal @referrer.id, referral.referrer_id
          assert_equal "pending", referral.status, "paid only after verification + the invitee's first activity"
        end

        test "the form carries the code as a hidden field so a lost cookie does not lose the referral" do
          get "#{base}?ref=ana_poziva"
          assert_select "input#mi-registration-ref[type=hidden][value=?]", "ana_poziva"

          # A brand-new session: the cookie the GET set is gone, only the form's
          # own field survives.
          reset!
          host! @organization.host
          params = registration_params.merge(ref: "ana_poziva")
          post base, params: params
          assert_response :redirect

          invitee = Decidim::User.find_by(email: params[:user][:email], organization: @organization)
          referral = Decidim::Bih::Goodwill::Referral.find_by(invitee_id: invitee.id)
          assert referral, "the hidden field alone attributed the registration"
          assert_equal @referrer.id, referral.referrer_id
        end

        test "a code that is not nickname-shaped is never echoed into the form" do
          get "#{base}?ref=#{CGI.escape("<script>x</script>")}"
          assert_response :success
          assert_select "input#mi-registration-ref", count: 0
        end

        test "an unknown code is ignored and registration still succeeds" do
          get "#{base}?ref=niko_takav"
          params = registration_params
          post base, params: params
          assert_response :redirect

          invitee = Decidim::User.find_by(email: params[:user][:email], organization: @organization)
          assert invitee
          assert_nil Decidim::Bih::Goodwill::Referral.find_by(invitee_id: invitee.id)
        end

        test "an old hub link still captures the code and offers registration" do
          get Decidim::Bih.public_path("zajednistvo?tab=pozovi&ref=ana_poziva")
          assert_response :success
          assert_includes response.body, "#{base}?ref=ana_poziva"

          params = registration_params
          post base, params: params
          invitee = Decidim::User.find_by(email: params[:user][:email], organization: @organization)
          assert Decidim::Bih::Goodwill::Referral.find_by(invitee_id: invitee.id, referrer_id: @referrer.id)
        end

        # A referral row points at the invitee with a plain foreign key and no ON
        # DELETE, so "Počni ispočetka" used to raise ActiveRecord::InvalidForeignKey
        # — an unrescued 500 that left the account in place. The citizen who
        # mistyped their number AND arrived through an invite link was the one it
        # hit (review 2026-09-07, lane 2 H1).
        test "starting over works for a citizen who registered through a referral link" do
          get "#{base}?ref=ana_poziva"
          params = registration_params
          post base, params: params

          invitee = Decidim::User.find_by(email: params[:user][:email], organization: @organization)

          assert Decidim::Bih::Goodwill::Referral.exists?(invitee_id: invitee.id)

          post "#{base}/potvrda/pocni-ispocetka"

          assert_redirected_to base
          assert_nil Decidim::User.find_by(id: invitee.id), "the never-verified account is gone"
          refute Decidim::Bih::Goodwill::Referral.exists?(invitee_id: invitee.id),
                 "the pending referral row went with it"
        end
      end
    end
  end
end
