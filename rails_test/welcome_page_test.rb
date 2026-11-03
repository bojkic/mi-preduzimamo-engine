# frozen_string_literal: true

require "test_helper"
require "rake"

module Decidim
  module Bih
    module RailsHarness
      # "/dobrodosli" — the first page a citizen sees after the phone number is
      # verified and the komšiluk is picked. It is the ONE place that turns a
      # finished verification into "here is what you can do now", so it is also
      # the page whose read/write split matters most:
      #
      #   * GET renders and writes NOTHING (Onboarding::NextStep is consulted
      #     from GET-time redirects and is side-effect free; a GET that stamped
      #     the citizen would make a plain page load change onboarding state,
      #     and a prefetch or a double-render would silently skip the page).
      #   * POST ("Krenimo") is the only writer of mi_welcomed_at.
      class WelcomePageTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        WELCOMED_KEY = "mi_welcomed_at"

        setup do
          @organization = create_organization
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Bih::Goodwill::Ledger.new.award(@citizen, 20, reason: "test_seed")
          sign_in @citizen
          # /dobrodosli is the tail of the phone-first onboarding chain; it is
          # only ever reached on a host that has that switch on, by a citizen
          # who has finished the chain. Both actions gate on that, so it is the
          # setup for every test except the two that probe the gate itself.
          Decidim::Bih.phone_first_registration = true
          finish_onboarding!
        end

        teardown { Decidim::Bih.phone_first_registration = false }

        def welcome_page_path = Decidim::Bih.public_path("dobrodosli")

        def welcomed_at = @citizen.reload.extended_data.to_h[WELCOMED_KEY]

        def grant_sms!
          Decidim::Authorization.create!(
            user: @citizen, name: "sms", unique_id: "u-#{@citizen.id}", granted_at: Time.current
          )
        end

        def assign_komsiluk!
          Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization)
                                      .assign_komsiluk!(build_komsiluk!(@organization), source: "registration")
        end

        def finish_onboarding!
          grant_sms!
          assign_komsiluk!
        end

        # A signed-in citizen who has NOT finished the chain. Devise's sign_in
        # replaces the session user, so the gate tests run as this one.
        def sign_in_newcomer!
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          sign_in @citizen
          @citizen
        end

        test "shows the balance and evergreen actions without inventing an invitation" do
          get welcome_page_path

          assert_response :success
          assert_equal 20, goodwill_balance_for(@citizen)
          assert_includes response.body, I18n.t("decidim.bih.welcome.show.points", count: 20, locale: :sr)
          assert_includes response.body, I18n.t("decidim.bih.welcome.show.community_next", locale: :sr)
          assert_select ".mi-welcome__invitation", count: 0
          assert_select "a[href=?]", "#{Decidim::Bih.public_path("prijave/new")}?locale=sr"
          assert_select "a[href=?]", "/processes"
          invitation_links = css_select("a[href]").filter_map do |anchor|
            uri = URI.parse(anchor["href"])
            next unless uri.scheme.nil? && uri.host.nil? && uri.path == Decidim::Bih.public_path("zajednistvo")

            Rack::Utils.parse_nested_query(uri.query)
          end
          assert_includes invitation_links, { "locale" => "sr", "tab" => "pozovi" }
          # No Milica button on the welcome page since 2026-09-07: the chat
          # bubble is on every page already.
          assert_select "[data-mi-bot-open]", count: 0
        end

        test "offers a sign out for a code typed on someone else's phone" do
          get welcome_page_path

          assert_response :success
          assert_includes response.body, I18n.t("decidim.bih.welcome.show.logout_hint", locale: :sr)
          assert_select "form[action=?]", "/sr/users/sign_out"
        end

        test "a GET never marks the citizen welcomed" do
          get welcome_page_path

          assert_response :success
          assert_nil welcomed_at
        end

        # The PWA marker is appended by CompletesPhoneAuthentication for the
        # verify purpose, so the welcome page is always reached with ?app=1
        # after a phone verification. public/mi/mi-install.js reads it from the
        # query string, so the page must render with it and must not strip it.
        test "renders with the PWA app=1 marker the verification appends" do
          get "#{welcome_page_path}?app=1"

          assert_response :success
        end

        test "anonymous visitors are sent to sign in" do
          sign_out @citizen

          get welcome_page_path

          assert_redirected_to "/sr/users/sign_in"
        end

        test "Krenimo marks the citizen welcomed and sends them to the account setup" do
          post welcome_page_path

          assert_redirected_to "#{Decidim::Bih.public_path("moj-nalog")}?setup=1"
          assert welcomed_at.present?
        end

        test "a second Krenimo keeps the first timestamp" do
          post welcome_page_path
          first = welcomed_at

          travel 5.minutes do
            post welcome_page_path
          end

          assert_equal first, welcomed_at
        end

        # "Nalog je potvrđen" would be a lie to a citizen who has not verified,
        # so the GET is gated exactly like the POST: they are sent to the step
        # they are really on.
        test "a citizen who has not verified is sent to the step they are on, not congratulated" do
          sign_in_newcomer!

          get welcome_page_path

          assert_redirected_to Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr)
        end

        # Typing the URL before the phone is verified must not burn the welcome
        # step: the citizen is sent to the step they are actually on, unstamped,
        # so the page still greets them once verification finishes.
        test "Krenimo before verification does not stamp and routes to the real next step" do
          sign_in_newcomer!

          post welcome_page_path

          assert_redirected_to Decidim::Bih::Onboarding::NextStep.sms_new_path(locale: :sr)
          assert_nil welcomed_at
        end

        test "anonymous Krenimo is refused" do
          sign_out @citizen

          post welcome_page_path

          assert_redirected_to "/sr/users/sign_in"
          assert_nil welcomed_at
        end

        # The invitation threshold is the launch-invitation reward's cost, not a
        # number this page owns — the campaign quotes it, so the page and the
        # rewards tab can never disagree.
        test "expired launch reward does not show invitation progress" do
          Decidim::Bih::Goodwill::Reward.create!(organization: @organization,
            key: Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY, title: { "sr" => "Old invitation" },
            cost: 20, stock: 10, deducts_points: false, auto_issue_at_threshold: true, expires_at: 1.second.ago)
          get welcome_page_path
          assert_response :success
          assert_select ".mi-welcome__invitation", count: 0
          assert_includes response.body, I18n.t("decidim.bih.welcome.show.community_next", locale: :sr)
        end

        test "spending wallet points does not remove the earned invitation qualification" do
          Decidim::Bih::Goodwill::Reward.create!(
            organization: @organization,
            key: Decidim::Bih::Goodwill::LaunchInvitation::REWARD_KEY,
            title: { "sr" => "Pozivnica za lansiranje" },
            cost: 20, stock: 10,
            deducts_points: false, auto_issue_at_threshold: true
          )

          Decidim::Bih::Goodwill::Ledger.new.spend(owner: @citizen, amount: 10, kind: "redeem", reason: "test_redemption")
          assert_equal 10, goodwill_balance_for(@citizen)

          get welcome_page_path

          assert_response :success
          assert_select ".mi-welcome__invitation[data-state='ready']"
          assert_includes response.body, I18n.t("decidim.bih.welcome.show.ready", locale: :sr)
        end
      end

      # R-D8: /dobrodosli is not retroactive. Citizens who verified before this
      # shipped are stamped once by the rake task, so they never get a welcome
      # page weeks into their membership. The rake task is a thin printer over
      # this service.
      class WelcomeBackfillTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
        end

        def verified_citizen!
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: citizen, name: "sms", unique_id: "u-#{citizen.id}", granted_at: Time.current
          )
          Decidim::Bih::CitizenProfile.for_user(citizen, organization: @organization)
                                      .assign_komsiluk!(build_komsiluk!(@organization), source: "registration")
          citizen
        end

        test "stamps verified citizens with a komsiluk and counts them" do
          verified = verified_citizen!
          unverified = FactoryBot.create(:user, :confirmed, organization: @organization)
          no_komsiluk = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: no_komsiluk, name: "sms", unique_id: "u-#{no_komsiluk.id}", granted_at: Time.current
          )

          counts = Decidim::Bih::Onboarding::Welcome.backfill!(@organization)

          assert_equal 1, counts[:scanned]
          assert_equal 1, counts[:stamped]
          assert verified.reload.extended_data.to_h["mi_welcomed_at"].present?
          assert_nil unverified.reload.extended_data.to_h["mi_welcomed_at"]
          assert_nil no_komsiluk.reload.extended_data.to_h["mi_welcomed_at"]
        end

        test "is idempotent: a second run stamps nobody" do
          verified = verified_citizen!
          Decidim::Bih::Onboarding::Welcome.backfill!(@organization)
          first = verified.reload.extended_data.to_h["mi_welcomed_at"]

          counts = Decidim::Bih::Onboarding::Welcome.backfill!(@organization)

          assert_equal 1, counts[:scanned]
          assert_equal 0, counts[:stamped]
          assert_equal first, verified.reload.extended_data.to_h["mi_welcomed_at"]
        end

        test "never reaches into another organization" do
          other_organization = create_organization
          verified = verified_citizen!

          counts = Decidim::Bih::Onboarding::Welcome.backfill!(other_organization)

          assert_equal 0, counts[:scanned]
          assert_nil verified.reload.extended_data.to_h["mi_welcomed_at"]
        end
      end

      # The rake task an operator actually runs. It is a thin printer over the
      # service above, and two things only the task can get wrong: a host
      # nobody typed correctly must stop BEFORE it touches a row, and the
      # output must be counts and nothing else — no name, no e-mail, no phone,
      # no id (the backfill walks every verified citizen in an organization,
      # so its stdout is the widest PII surface this flow has).
      class WelcomeBackfillTaskTest < ActiveSupport::TestCase
        TASK = "decidim_bih:registration:backfill_welcomed"

        setup do
          @organization = create_organization
          @previous_rake = Rake.application
          # A fresh application per test: a Rake task remembers it was already
          # invoked, and these tests invoke the same one repeatedly.
          Rake.application = Rake::Application.new
          # The task's :environment prerequisite is Rails'; this process is
          # already booted, so here it is a no-op that only has to exist.
          Rake::Task.define_task(:environment)
          load File.expand_path("../lib/tasks/decidim_bih_registration.rake", __dir__)
        end

        teardown { Rake.application = @previous_rake }

        def verified_citizen!(welcomed: false)
          citizen = FactoryBot.create(:user, :confirmed, organization: @organization,
                                                         name: "Nadežda Prezimenović")
          Decidim::Authorization.create!(
            user: citizen, name: "sms", unique_id: "u-#{citizen.id}", granted_at: Time.current
          )
          Decidim::Bih::CitizenProfile.for_user(citizen, organization: @organization)
                                      .assign_komsiluk!(build_komsiluk!(@organization), source: "registration")
          Decidim::Bih::Onboarding::Welcome.mark!(citizen) if welcomed
          citizen
        end

        test "an unknown host stops before the task touches a single row" do
          citizen = verified_citizen!
          error = nil

          stdout, stderr = capture_io do
            error = assert_raises(SystemExit) { Rake.application[TASK].invoke("nobody.example") }
          end

          assert_match(/Organization not found for host: nobody\.example/, error.message)
          assert_match(/Organization not found/, stderr)
          assert_empty stdout, "an aborted run prints no counts, because it counted nothing"
          assert_nil citizen.reload.extended_data.to_h["mi_welcomed_at"]
        end

        test "no host at all is the same refusal, not a run over every organization" do
          citizen = verified_citizen!
          error = nil

          capture_io { error = assert_raises(SystemExit) { Rake.application[TASK].invoke } }

          assert_match(/Organization not found for host: /, error.message)
          assert_nil citizen.reload.extended_data.to_h["mi_welcomed_at"]
        end

        test "a valid host prints the three counts and nothing else at all" do
          fresh = verified_citizen!
          already = verified_citizen!(welcomed: true)

          stdout, = capture_io { Rake.application[TASK].invoke(@organization.host) }

          # The WHOLE output, not a match inside it: that is what makes "counts
          # only" an assertion rather than a hope.
          assert_equal(
            "Verified citizens with a komšiluk: 2. Stamped now: 1. Already welcomed: 1.\n",
            stdout
          )
          assert fresh.reload.extended_data.to_h["mi_welcomed_at"].present?
          [fresh.name, fresh.email, fresh.nickname, already.email].each do |identifier|
            refute_includes stdout, identifier
          end
        end
      end
    end
  end
end
