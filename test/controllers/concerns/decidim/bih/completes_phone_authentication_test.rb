# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/hash/keys"
require_relative "../../../../../app/services/decidim/bih/komsiluk/return_path"
require_relative "../../../../../app/services/decidim/bih/citizen_return_path"
require_relative "../../../../../app/controllers/concerns/decidim/bih/completes_phone_authentication"

module Decidim
  module Bih
    class CompletesPhoneAuthenticationTest < Minitest::Test
      Organization = Struct.new(:id)

      User = Struct.new(:id, :active, :blocked_value, :deleted_value) do
        def active_for_authentication? = active

        def blocked? = blocked_value

        def deleted? = deleted_value
      end

      class Routes
        def account_overview_path(anchor: nil)
          anchor ? "/moj-nalog##{anchor}" : "/moj-nalog"
        end
      end

      class Harness
        include CompletesPhoneAuthentication

        attr_reader :events, :flash, :redirected_to, :session
        attr_accessor :current_user

        def initialize(current_user: nil)
          @current_user = current_user
          @events = []
          @flash = {}
          @session = {}
        end

        def call(**) = complete_phone_authentication(**)

        def user_signed_in? = !current_user.nil?

        def current_organization = Organization.new(42)

        def decidim_bih = Routes.new

        def t(key) = key

        def reset_session
          events << :reset_session
        end

        def sign_in(scope, user)
          events << [:sign_in, scope, user]
          self.current_user = user
        end

        def synchronize_proven_phone(user, phone)
          events << [:synchronize, user, phone]
        end

        def redirect_to(path)
          events << [:redirect, path]
          @redirected_to = path
        end
      end

      def setup
        @user = User.new(7, true, false, false)
      end

      def test_grant_and_token_claim_both_finish_before_new_session_sign_in
        harness = Harness.new
        grant = lambda do
          harness.events << :grant
          true
        end
        consume = lambda do
          harness.events << :consume
          true
        end

        assert harness.call(user: @user, purpose: "login", grant:, consume:)
        assert_equal [:grant, :consume, :reset_session, [:sign_in, :user, @user], [:redirect, "/moj-nalog"]], harness.events
      end

      def test_phone_contact_repair_happens_only_after_both_proof_steps
        harness = Harness.new
        phone = "+38765123456"
        grant = lambda {
          harness.events << :grant
          true
        }
        consume = lambda {
          harness.events << :consume
          true
        }

        assert harness.call(user: @user, purpose: "login", phone:, grant:, consume:)
        assert_equal [:grant, :consume, [:synchronize, @user, phone]], harness.events.first(3)
      end

      def test_failed_proof_never_repairs_phone_contacts
        harness = Harness.new
        refute harness.call(user: @user, purpose: "login", phone: "+38765123456", grant: -> { true }, consume: -> { false })
        assert_empty harness.events
        refute harness.call(user: @user, purpose: "login", phone: "+38765123456", grant: -> { false })
        assert_empty harness.events
      end

      def test_failed_grant_never_claims_proof_or_signs_in
        harness = Harness.new
        consume_called = false

        refute harness.call(user: @user, purpose: "verify", grant: -> { false }, consume: -> { consume_called = true })
        refute consume_called
        assert_empty harness.events
      end

      def test_failed_atomic_claim_never_signs_in
        harness = Harness.new

        refute harness.call(user: @user, purpose: "verify", grant: -> { true }, consume: -> { false })
        assert_empty harness.events
      end

      def test_existing_same_user_session_is_preserved
        harness = Harness.new(current_user: @user)

        assert harness.call(user: @user, purpose: "login", grant: -> { true }, consume: -> { true })
        assert_equal [[:redirect, "/moj-nalog"]], harness.events
      end

      def test_existing_different_user_session_is_rejected_before_grant
        harness = Harness.new(current_user: User.new(8, true, false, false))
        grant_called = false

        refute harness.call(user: @user, purpose: "login", grant: -> { grant_called = true }, consume: -> { true })
        refute grant_called
        assert_empty harness.events
      end

      def test_inactive_blocked_and_deleted_users_are_rejected
        [User.new(8, false, false, false), User.new(9, true, true, false), User.new(10, true, false, true)].each do |user|
          harness = Harness.new
          refute harness.call(user:, purpose: "login", grant: -> { true })
          assert_empty harness.events
        end
      end

      def test_successful_verification_gets_one_app_marker_before_fragment
        harness_class = Class.new(Harness) do
          private

          def phone_authentication_next_step_path(*)
            "/komsiluk?setup=1#zavrsi-nalog"
          end
        end
        harness = harness_class.new

        assert harness.call(user: @user, purpose: "verify", grant: -> { true })
        assert_equal "/komsiluk?setup=1&app=1#zavrsi-nalog", harness.redirected_to
      end

      # The destination override is request data one hop removed (the
      # verification page forwards Decidim's redirect_url), so it is treated
      # as untrusted here rather than trusted because a controller passed it.
      def test_caller_destination_is_honoured_when_it_is_a_host_relative_path
        harness = Harness.new

        assert harness.call(user: @user, purpose: "login", grant: -> { true }, destination: "/prijave/12?x=1#y")
        assert_equal "/prijave/12?x=1#y", harness.redirected_to
      end

      def test_off_site_caller_destinations_are_ignored_for_the_next_step
        [
          "//evil.example/steal",
          "/\\evil.example",
          "https://evil.example",
          "http://evil.example",
          "javascript:alert(1)",
          "prijave/12",
          "/",
          "",
          "  /prijave/12"
        ].each do |destination|
          harness = Harness.new

          assert harness.call(user: @user, purpose: "login", grant: -> { true }, destination:)
          assert_equal "/moj-nalog", harness.redirected_to, destination.inspect
        end
      end

      def test_phone_login_returns_to_private_citizen_intent_after_session_reset
        harness = Harness.new
        path = Decidim::Bih.public_path("moj-nalog/poruke")
        CitizenReturnPath.store(harness.session, organization: harness.current_organization, path:)

        assert harness.call(user: @user, purpose: "login", grant: -> { true }, consume: -> { true })
        assert_equal path, harness.redirected_to
        assert_nil CitizenReturnPath.consume(harness.session, organization: harness.current_organization)
      end

      def test_board_destination_keeps_priority_over_citizen_intent
        harness = Harness.new
        board_path = Decidim::Bih.public_path("komsiluk-board")
        citizen_path = Decidim::Bih.public_path("moj-doprinos")
        Komsiluk::ReturnPath.store(harness.session, organization: harness.current_organization, path: board_path)
        CitizenReturnPath.store(harness.session, organization: harness.current_organization, path: citizen_path)

        assert harness.call(user: @user, purpose: "login", grant: -> { true }, consume: -> { true })
        assert_equal board_path, harness.redirected_to
      end

      def test_failed_login_proof_does_not_consume_citizen_intent
        harness = Harness.new
        path = Decidim::Bih.public_path("moj-nalog")
        CitizenReturnPath.store(harness.session, organization: harness.current_organization, path:)

        refute harness.call(user: @user, purpose: "login", grant: -> { true }, consume: -> { false })
        assert_equal path, CitizenReturnPath.consume(harness.session, organization: harness.current_organization)
      end

      def test_returning_login_does_not_add_registration_install_marker
        harness = Harness.new

        assert harness.call(user: @user, purpose: "login", grant: -> { true })
        assert_equal "/moj-nalog", harness.redirected_to
      end

      # Defines Decidim::Bih::Onboarding::NextStep and the phone-first switch
      # for the duration of the block, then takes both away again.
      def with_onboarding_chain(phone_first:)
        previous_onboarding = Decidim::Bih.const_get(:Onboarding, false) if Decidim::Bih.const_defined?(:Onboarding, false)
        Decidim::Bih.send(:remove_const, :Onboarding) if previous_onboarding
        onboarding = Module.new
        next_step = Module.new do
          define_singleton_method(:for) do |user, organization:|
            raise "wrong user" unless user.id == 7
            raise "wrong organization" unless organization.id == 42

            "/komsiluk?setup=1"
          end
        end
        onboarding.const_set(:NextStep, next_step)
        Decidim::Bih.const_set(:Onboarding, onboarding)
        restore = swap_phone_first_registration(phone_first)
        yield
      ensure
        Decidim::Bih.send(:remove_const, :Onboarding) if Decidim::Bih.const_defined?(:Onboarding, false)
        Decidim::Bih.const_set(:Onboarding, previous_onboarding) if previous_onboarding
        restore&.call
      end

      # Decidim::Bih carries the real switch as an ActiveSupport config_accessor
      # when lib/decidim/bih.rb is loaded (the whole-suite run) and does not
      # exist at all when this file runs on its own. Set it whichever way
      # applies and hand back the undo — removing the accessor outright would
      # take the real one with it for the rest of the process.
      def swap_phone_first_registration(value)
        if Decidim::Bih.respond_to?(:phone_first_registration=)
          previous = Decidim::Bih.phone_first_registration
          Decidim::Bih.phone_first_registration = value
          -> { Decidim::Bih.phone_first_registration = previous }
        else
          Decidim::Bih.define_singleton_method(:phone_first_registration) { value }
          -> { Decidim::Bih.singleton_class.send(:remove_method, :phone_first_registration) }
        end
      end

      def test_phone_flows_use_shared_onboarding_next_step_when_available
        harness = Harness.new

        with_onboarding_chain(phone_first: true) do
          assert harness.call(user: @user, purpose: "verify", grant: -> { true })
        end

        assert_equal "/komsiluk?setup=1&app=1", harness.redirected_to
      end

      # A host that has not switched phone-first on registers no :sms
      # verification workflow, so the first step of the chain
      # (/sms/authorizations/new) is a 404 there. The account checklist is the
      # only honest destination, whatever NextStep would have answered.
      def test_next_step_is_skipped_when_phone_first_registration_is_off
        harness = Harness.new

        with_onboarding_chain(phone_first: false) do
          assert harness.call(user: @user, purpose: "verify", grant: -> { true })
        end

        assert_equal "/moj-nalog?app=1#zavrsi-nalog", harness.redirected_to
      end
    end
  end
end
