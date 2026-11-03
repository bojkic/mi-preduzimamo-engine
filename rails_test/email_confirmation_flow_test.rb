# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # "Potvrdi e-mail" in Moj nalog. Phone-first sign-up activates the account
      # without an e-mail round trip, so the address a citizen typed is unproven
      # until they follow a link sent to it. This step proves the ADDRESS and
      # nothing else: it never verifies the phone and never grants points.
      class EmailConfirmationFlowTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveJob::TestHelper

        REQUEST_PATH = Decidim::Bih.public_path("potvrdi-email")
        ACCOUNT_PATH = "#{Decidim::Bih.public_path("moj-nalog")}?locale=sr".freeze
        TTL = Decidim::Bih::EmailConfirmationsController::TTL

        setup do
          @organization = create_organization
          host! @organization.host
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @password = @citizen.password
          sign_in @citizen
        end

        teardown do
          Decidim::Bih.phone_first_registration = false
          Decidim::Bih.phone_first_registration_since = nil
        end

        test "requesting sends a mail and the link proves exactly that address" do
          link = request_confirmation_link

          get link

          assert_redirected_to ACCOUNT_PATH
          assert_equal I18n.t("decidim.bih.email_confirmations.show.confirmed", locale: :sr), flash[:notice]
          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
          assert_equal @citizen.email.downcase,
                       @citizen.extended_data[Decidim::Bih::EmailConfirmation::KEY]["address"]
        end

        test "account checklist and email panel agree before proof, after proof and after address change" do
          get ACCOUNT_PATH
          assert_response :success
          refute Decidim::Bih::AccountSummary.new(organization: @organization, user: @citizen).email_confirmed?
          assert_select "#potvrda-emaila .mi-account-email-confirmation__status",
                        text: I18n.t("decidim.bih.account.email_confirmation.unconfirmed", locale: :sr)

          get request_confirmation_link
          @citizen.reload
          assert Decidim::Bih::AccountSummary.new(organization: @organization, user: @citizen).email_confirmed?
          get ACCOUNT_PATH
          assert_select "#potvrda-emaila .mi-account-email-confirmation__status",
                        text: I18n.t("decidim.bih.account.email_confirmation.confirmed", locale: :sr)

          @citizen.update_columns(email: "changed-#{@citizen.id}@example.invalid") # rubocop:disable Rails/SkipsModelValidations
          refute Decidim::Bih::AccountSummary.new(organization: @organization, user: @citizen.reload).email_confirmed?
          get ACCOUNT_PATH
          assert_select "#potvrda-emaila .mi-account-email-confirmation__status",
                        text: I18n.t("decidim.bih.account.email_confirmation.unconfirmed", locale: :sr)
        end

        # The message goes to the address being proven and to nobody else, and
        # it carries exactly one credential — a second link (a stale one left in
        # a template, a duplicated paragraph) would be a second thing to leak.
        test "the message reaches only that address and carries exactly one link" do
          assert_equal 1, (mails_sent { post(REQUEST_PATH) })

          mail = ActionMailer::Base.deliveries.last

          assert_equal [@citizen.email], mail.to
          assert_equal 1, token_urls_in(mail).length
        end

        test "a link minted for an old address is refused after the address changed" do
          link = request_confirmation_link
          @citizen.update_columns(email: "nova-#{@citizen.id}@example.org") # rubocop:disable Rails/SkipsModelValidations

          get link

          assert_equal I18n.t("decidim.bih.email_confirmations.show.invalid", locale: :sr), flash[:alert]
          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
        end

        test "a link older than its two days is refused" do
          link = request_confirmation_link

          travel_to (TTL + 1.hour).from_now do
            sign_in @citizen
            get link

            assert_equal I18n.t("decidim.bih.email_confirmations.show.invalid", locale: :sr), flash[:alert]
          end

          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
        end

        test "a tampered token is refused" do
          link = request_confirmation_link
          tampered = "#{link[0..-2]}#{link[-1] == "a" ? "b" : "a"}"

          get tampered

          assert_equal I18n.t("decidim.bih.email_confirmations.show.invalid", locale: :sr), flash[:alert]
          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
        end

        test "a token that is not a signed id at all is refused" do
          get "#{REQUEST_PATH}/not-a-token"

          assert_redirected_to ACCOUNT_PATH
          assert_equal I18n.t("decidim.bih.email_confirmations.show.invalid", locale: :sr), flash[:alert]
          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
        end

        # The link proves an address, never a phone number. A citizen who only
        # clicks it must stay unverified, or the e-mail step would quietly buy
        # the rights that only the SMS/Viber round trip may grant.
        test "following the link never verifies the phone" do
          link = request_confirmation_link

          get link

          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
          refute Decidim::Authorization.where(user: @citizen).where.not(granted_at: nil).exists?,
                 "the e-mail link must not grant any authorization"
          assert_equal 0, goodwill_balance_for(@citizen)
        end

        test "another citizen's link proves nothing for the signed-in citizen" do
          link = request_confirmation_link
          intruder = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in intruder

          get link

          assert_equal I18n.t("decidim.bih.email_confirmations.show.invalid", locale: :sr), flash[:alert]
          refute Decidim::Bih::EmailConfirmation.confirmed?(intruder.reload)
          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
        end

        # The whole point of not passing the token as `redirect_url`: Decidim's
        # HasStoredPath has already parked the destination in the session, so
        # signing in returns the citizen to the link with the credential never
        # having appeared in the sign-in URL.
        test "a signed-out click proves nothing until the citizen signs in, then completes" do
          link = request_confirmation_link
          sign_out @citizen

          get link

          assert_redirected_to "/sr/users/sign_in"
          refute_includes response.location.to_s, "potvrdi-email",
                          "the token must not be copied into the sign-in URL"
          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)

          post "/sr/users/sign_in", params: { user: { email: @citizen.email, password: @password } }

          assert_redirected_to link
          follow_redirect!

          assert_redirected_to ACCOUNT_PATH
          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)
        end

        # The URL carries a bearer token: it must not be cached by a shared
        # proxy, handed to the next site as a referrer, or indexed.
        test "the token page is private, unindexed and never referred" do
          link = request_confirmation_link

          get link

          assert_equal %w(no-store private), response.headers["Cache-Control"].to_s.split(/,\s*/).sort
          assert_equal "strict-origin", response.headers["Referrer-Policy"]
          assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
        end

        test "a second request inside the cooldown sends nothing" do
          assert_equal 1, (mails_sent { post(REQUEST_PATH) })
          assert_equal 0, (mails_sent { post(REQUEST_PATH) })

          assert_redirected_to ACCOUNT_PATH
          assert_equal I18n.t("decidim.bih.email_confirmations.create.cooldown", locale: :sr), flash[:alert]
        end

        test "a request after the cooldown sends again" do
          assert_equal 1, (mails_sent { post(REQUEST_PATH) })

          travel_to 21.minutes.from_now do
            assert_equal 1, (mails_sent { post(REQUEST_PATH) })
          end
        end

        test "a request for an address already proven sends nothing" do
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)

          assert_equal 0, (mails_sent { post(REQUEST_PATH) })
          assert_redirected_to ACCOUNT_PATH
          assert_equal I18n.t("decidim.bih.email_confirmations.create.already_confirmed", locale: :sr), flash[:notice]
        end

        test "the account page offers the confirmation while unproven" do
          get ACCOUNT_PATH

          assert_includes response.body, I18n.t("decidim.bih.account.email_confirmation.cta", locale: :sr)
        end

        test "the account page reports the address as proven once it is" do
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)

          get ACCOUNT_PATH

          assert_includes response.body, I18n.t("decidim.bih.account.email_confirmation.confirmed", locale: :sr)
          refute_includes response.body, I18n.t("decidim.bih.account.email_confirmation.cta", locale: :sr)
        end

        test "a signed-out request sends nothing" do
          sign_out @citizen

          assert_equal 0, (mails_sent { post(REQUEST_PATH) })
          assert_response :redirect
        end

        private

        # The mailer runs on its own delivery job (the token must not reach the
        # ActiveJob log), so count deliveries directly instead of relying on
        # assert_emails, whose filter only knows the mailers already loaded.
        def mails_sent(&)
          before = ActionMailer::Base.deliveries.size
          perform_enqueued_jobs(only: Decidim::Bih::EmailConfirmationDeliveryJob, &)
          ActionMailer::Base.deliveries.size - before
        end

        def token_urls_in(mail)
          body = (mail.html_part || mail.text_part || mail).decoded
          body.scan(%r{https?://[^\s"'<>]*#{Regexp.escape(REQUEST_PATH)}/[^\s"'<>]+})
        end

        # Drive the real flow rather than re-minting the token in the test: the
        # link the citizen actually receives is the only thing worth asserting
        # on, and it keeps the token recipe a controller detail.
        def request_confirmation_link
          assert_equal 1, (mails_sent { post(REQUEST_PATH) })

          urls = token_urls_in(ActionMailer::Base.deliveries.last)

          refute_empty urls, "the confirmation e-mail must carry the link"
          URI.parse(urls.first).request_uri
        end
      end
    end
  end
end
