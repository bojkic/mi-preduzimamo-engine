# frozen_string_literal: true

require "test_helper"
require "uri"

module Decidim
  module Bih
    module RailsHarness
      class PhoneCodeSessionsTest < ActionDispatch::IntegrationTest
        PHONE = "+38765123456"

        class AttemptStore
          attr_reader :counts

          def initialize
            @counts = Hash.new(0)
          end

          def available! = true

          def record_attempt!(organization_id:, user_id:, purpose:, **)
            @counts[[organization_id, user_id, purpose]] += 1
          end

          def extend_expiry!(**) = true

          def clear(organization_id:, user_id:, purpose:)
            @counts.delete([organization_id, user_id, purpose])
          end
        end

        setup do
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @authorization = Decidim::Authorization.create!(
            user: @citizen,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            granted_at: Time.current
          )
        end

        test "fresh challenge sends one shared code and signs in only after its atomic claim" do
          with_phone_challenge do |delivery|
            post Decidim::Bih.public_path("prijava"), params: { phone: PHONE }
            assert_response :redirect

            code = delivery.fetch(:otp_code)
            raw = delivery.fetch(:test_raw_token)
            assert_includes delivery.fetch(:text), code
            refute_includes delivery.fetch(:viber_text), code
            assert_in_delta 10.minutes.to_i, delivery.fetch(:expires_at) - Time.current, 2

            follow_redirect!
            assert_response :success
            refute_includes response.body, raw
            refute_includes response.body, code

            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: code }
            assert_response :redirect
            assert_nil LoginToken.find_by(token_digest: LoginToken.digest(raw), consumed_at: nil)

            get Decidim::Bih.public_path("moj-nalog")
            assert_response :success
          end
        end

        test "wrong code does not consume the link or open a session" do
          with_phone_challenge do |delivery|
            request_challenge
            raw = delivery.fetch(:test_raw_token)
            wrong = delivery.fetch(:otp_code) == "000000" ? "000001" : "000000"

            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: wrong }

            assert_response :unprocessable_entity
            assert LoginToken.find_by(token_digest: LoginToken.digest(raw), consumed_at: nil)
            assert_anonymous
          end
        end

        test "expired code does not sign in" do
          with_phone_challenge do |delivery|
            request_challenge
            raw = delivery.fetch(:test_raw_token)
            LoginToken.find_by!(token_digest: LoginToken.digest(raw)).update!(expires_at: 1.second.ago)

            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: delivery.fetch(:otp_code) }

            assert_response :unprocessable_entity
            assert_anonymous
          end
        end

        test "replayed code cannot claim the consumed login token twice" do
          with_phone_challenge do |delivery|
            request_challenge
            code = delivery.fetch(:otp_code)
            raw = delivery.fetch(:test_raw_token)

            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: code }
            assert_response :redirect
            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: code }

            assert_response :unprocessable_entity
            assert_equal 1, LoginToken.where(token_digest: LoginToken.digest(raw)).where.not(consumed_at: nil).count
          end
        end

        test "session challenge cannot cross organizations" do
          other_organization = create_organization

          with_phone_challenge do |delivery|
            request_challenge
            raw = delivery.fetch(:test_raw_token)
            host! other_organization.host

            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: delivery.fetch(:otp_code) }

            assert_response :unprocessable_entity
            assert LoginToken.find_by(token_digest: LoginToken.digest(raw), consumed_at: nil)
            assert_anonymous
          end
        end

        test "authorization removed after send fails grant and opens no session" do
          with_phone_challenge do |delivery|
            request_challenge
            raw = delivery.fetch(:test_raw_token)
            @authorization.destroy!

            post Decidim::Bih.public_path("prijava/kod"), params: { verification_code: delivery.fetch(:otp_code) }

            assert_response :unprocessable_entity
            assert LoginToken.find_by(token_digest: LoginToken.digest(raw), consumed_at: nil)
            assert_anonymous
          end
        end

        test "duplicate active phone grants fail closed without choosing a user" do
          other_citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: other_citizen,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            verification_metadata: {},
            granted_at: Time.current
          )

          with_phone_challenge do |delivery|
            request_challenge

            assert_empty delivery
            assert_equal 0, LoginToken.where(purpose: "login", consumed_at: nil).count
            assert_anonymous
          end
        end

        # Every SMS this platform sends is GSM-7 Latin. The login SMS was the
        # exception: it rendered under the request locale, so an sr-Cyrl
        # reader got the machine transliteration of deliberately
        # diacritic-free Latin — misspelled Cyrillic, UCS-2 on the wire, and
        # therefore two paid segments instead of one. Viber implies a
        # smartphone, has no segment limit, and keeps the citizen's script.
        test "an sr-Cyrl reader gets a Latin login SMS and a Cyrillic Viber message" do
          previous_locales = I18n.available_locales
          I18n.available_locales = (previous_locales + [:"sr-Cyrl"]).uniq
          # The generated host is built with --locales=en,bs,hr,sr, so its
          # backend may never have been asked for the engine's sr-Cyrl file.
          # Load it explicitly (idempotent) or the assertions below would pass
          # on the fallback to sr and prove nothing.
          I18n.backend.load_translations(File.expand_path("../config/locales/sr-Cyrl.yml", __dir__))
          assert_match(/\p{Cyrillic}/,
                       I18n.t("decidim.bih.sms.login_link", url: "https://x/y", locale: :"sr-Cyrl"),
                       "this harness must really serve sr-Cyrl or the test below proves nothing")

          organization = create_organization(available_locales: BIH_RAILS_TEST_LOCALES + ["sr-Cyrl"])
          assert_includes organization.available_locales, "sr-Cyrl"
          host! organization.host
          citizen = FactoryBot.create(:user, :confirmed, organization:)
          Decidim::Authorization.create!(
            user: citizen,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            granted_at: Time.current
          )

          with_phone_challenge do |delivery|
            post Decidim::Bih.public_path("prijava"), params: { phone: PHONE, locale: "sr-Cyrl" }
            assert_response :redirect
            # Core 0.32 carries this locale in the path, not a query parameter.
            assert_equal "/sr-Cyrl/users/sign_in", URI.parse(response.location).path

            refute_match(/\p{Cyrillic}/, delivery.fetch(:text),
                         "a Cyrillic SMS is UCS-2, two segments, and machine-misspelled")
            assert_includes delivery.fetch(:text), delivery.fetch(:otp_code)
            assert_match(/\p{Cyrillic}/, delivery.fetch(:viber_text),
                         "Viber has no segment limit and keeps the citizen's own script")
          end
        ensure
          # Restore available_locales FIRST, then drop everything the backend
          # holds: I18n::Backend::Simple#store_translations silently discards a
          # locale that is not available, so the reload re-reads the host's
          # load path without the sr-Cyrl file this test pushed in. Leaving it
          # loaded would let a later test pass on a translation the real host
          # does not serve.
          I18n.available_locales = previous_locales
          I18n.backend.reload!
          host! @organization.host
        end

        test "GET magic-link preview never consumes the login proof" do
          raw = LoginToken.issue!(user: @citizen, purpose: "login", phone: PHONE)

          get Decidim::Bih.magic_link_path(raw)

          assert_response :success
          assert_nil LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
          assert_equal %w(no-store private), response.headers["Cache-Control"].split(/,\s*/).sort
        end

        test "verify magic link commits grant and sibling invalidation before sign-in and app marker" do
          @authorization.update!(granted_at: nil, verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current })
          raw = LoginToken.issue!(user: @citizen, purpose: "verify", phone: PHONE)
          LoginToken.create!(
            user: @citizen,
            organization: @organization,
            purpose: "verify",
            phone: PHONE,
            token_digest: LoginToken.digest(SecureRandom.urlsafe_base64(24)),
            expires_at: 10.minutes.from_now
          )

          post Decidim::Bih.magic_link_path(raw)

          assert_response :redirect
          assert_includes URI.decode_www_form(URI.parse(response.location).query.to_s), %w(app 1)
          assert @authorization.reload.granted?
          assert_equal 0, LoginToken.where(user: @citizen, purpose: "verify", consumed_at: nil).count
          assert_authenticated
        end

        test "verify magic link rolls its claim back when the phone grant fails" do
          @authorization.update!(
            granted_at: nil,
            verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current },
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+38765999999")
          )
          raw = LoginToken.issue!(user: @citizen, purpose: "verify", phone: PHONE)

          post Decidim::Bih.magic_link_path(raw)

          assert_response :unprocessable_entity
          assert_nil LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
          refute @authorization.reload.granted?
          assert_anonymous
        end

        test "already granted changed phone rejects an old verification link" do
          raw = LoginToken.issue!(user: @citizen, purpose: "verify", phone: PHONE)
          new_unique_id = Decidim::Bih::SmsAuthorization.unique_id_for("+38765999999")
          @authorization.update!(unique_id: new_unique_id)

          post Decidim::Bih.magic_link_path(raw)

          assert_response :unprocessable_entity
          assert_nil LoginToken.find_by!(token_digest: LoginToken.digest(raw)).consumed_at
          assert_equal new_unique_id, @authorization.reload.unique_id
          assert_anonymous
        end

        # M10 / host Task 9. "Registruj se" on the phone-login page pointed at
        # Decidim's /users/sign_up, which on a host serving the one-step form
        # at a root path is now a 302 hop into it. Every citizen-facing
        # "register" link in this engine reads Decidim::Bih.registration_path,
        # whose default is still Devise's path, so a host that has not moved
        # anywhere is unaffected.
        test "the phone-login page sends a new citizen to the registration path this host serves" do
          previous = Decidim::Bih.registration_path
          Decidim::Bih.registration_path = "/registracija"

          get Decidim::Bih.public_path("prijava")

          assert_redirected_to "/sr/users/sign_in"
          follow_redirect!
          assert_response :success
          # The page's own CTA, by its label: Decidim's layout carries "sign up"
          # links of its own that this engine does not own and does not touch.
          assert_select "a[href=?]", "/registracija",
                        text: I18n.t("decidim.devise.sessions.new.register", locale: :sr)
        ensure
          Decidim::Bih.registration_path = previous
        end

        private

        def request_challenge
          post Decidim::Bih.public_path("prijava"), params: { phone: PHONE }
          assert_response :redirect
        end

        def with_phone_challenge
          challenge = PhoneChallenge.new(attempt_store: AttemptStore.new)
          delivery = {}
          issue = lambda do |**args|
            result = challenge.issue!(**args)
            delivery[:test_raw_token] = result.raw_token
            result
          end
          verify = ->(**args) { challenge.verify_code(**args) }
          consume = ->(**args) { challenge.consume!(**args) }

          PhoneChallenge.stub(:issue!, issue) do
            PhoneChallenge.stub(:verify_code, verify) do
              PhoneChallenge.stub(:consume!, consume) do
                Decidim::Bih::Infobip::SendPhoneMessageJob.stub(:perform_later, ->(**args) { delivery.merge!(args) }) do
                  yield delivery
                end
              end
            end
          end
        end

        def assert_anonymous
          get Decidim::Bih.public_path("moj-nalog")
          assert_response :redirect
          assert_match(%r{/users/sign_in}, response.location)
        end

        def assert_authenticated
          get Decidim::Bih.public_path("moj-nalog")
          assert_response :success
        end
      end
    end
  end
end
