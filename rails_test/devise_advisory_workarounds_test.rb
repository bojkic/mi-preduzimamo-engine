# frozen_string_literal: true

require "test_helper"

# Engine workarounds for two Devise 4.9.4 advisories while Decidim 0.31 pins
# Devise ~> 4.7 (dependency audit 2026-10-21, Stage A):
#   app/overrides/decidim/user_email_change_race_override.rb   (CVE-2026-32700)
#   app/overrides/decidim/devise_timeout_redirect_override.rb  (CVE-2026-40295)
module Decidim
  module Bih
    module RailsHarness
      class DeviseAdvisoryWorkaroundsTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        # RandomStalling sleeps up to five seconds before responding. Same
        # class chain (so the prepended override is what answers), no sleep.
        class StallFreeFailureApp < ::RandomStalling
          private

          def sleep(*) = nil
        end

        HOST = "rails-test-devise.lvh.me"

        # --- CVE-2026-32700: confirmable email-change race ---------------------

        test "the email change race override is on Decidim::User" do
          assert Decidim::User < Decidim::Bih::UserEmailChangeRaceOverride
          assert_equal 1, Decidim::User.ancestors.count(Decidim::Bih::UserEmailChangeRaceOverride)
        end

        test "an ordinary email change still waits for reconfirmation" do
          user = create(:user, :confirmed, organization: create_organization, email: "gradjanin-#{SecureRandom.hex(3)}@example.org")
          original = user.email

          user.update!(email: "novi-#{user.id}@example.org")
          row = Decidim::User.find(user.id)

          assert_equal original, row.email
          assert_equal "novi-#{user.id}@example.org", row.unconfirmed_email
          assert_predicate row.confirmation_token, :present?
        end

        # Two concurrent requests on one account, each holding the row as it was
        # loaded. The account already has a pending change to the attacker's
        # address; request A asks for the victim's, request B re-asks for the
        # attacker's. Without the fix B's UPDATE leaves unconfirmed_email out
        # (unchanged from what B loaded) but writes B's token, so the row pairs
        # the VICTIM's address with the token mailed to the ATTACKER.
        test "the last email change writes its own address next to its own token" do
          user = create(:user, :confirmed, organization: create_organization, email: "gradjanin-#{SecureRandom.hex(3)}@example.org")
          attacker = "napadac-#{user.id}@example.org"
          victim = "zrtva-#{user.id}@example.org"
          user.update!(email: attacker)

          request_a = Decidim::User.find(user.id)
          request_b = Decidim::User.find(user.id)
          request_a.update!(email: victim)
          request_b.update!(email: attacker)

          row = Decidim::User.find(user.id)
          assert_equal request_b.confirmation_token, row.confirmation_token
          assert_equal attacker, row.unconfirmed_email,
                       "the stored token must belong to the address it was mailed to"
        end

        # --- CVE-2026-40295: timeout redirect via Referer ----------------------

        test "Decidim's failure app carries the timeout redirect override" do
          assert_equal ::RandomStalling, ::Devise.warden_config.failure_app
          assert ::RandomStalling < Decidim::Bih::DeviseTimeoutRedirectOverride
          assert_equal 1, ::RandomStalling.ancestors.count(Decidim::Bih::DeviseTimeoutRedirectOverride)
        end

        test "a cross-host Referer on a timed-out POST is reduced to a same-host path" do
          location = timeout_redirect(method: "POST", referer: "https://evil.example/phish/login?next=1#form")

          assert_equal HOST, location.host
          assert_equal "/phish/login", location.path
          assert_equal "next=1", location.query
        end

        test "a protocol-relative or slash-stuffed Referer stays on this host" do
          ["//evil.example/x", "https://#{HOST}///evil.example/x"].each do |referer|
            location = timeout_redirect(method: "POST", referer:)

            assert_equal HOST, location.host, referer
            assert_match %r{\A/(evil\.example/)?x\z}, location.path, referer
          end
        end

        test "a Referer that is not an absolute path falls back to sign-in" do
          ["javascript:alert(1)", ".evil.example", "evil.example/x", "http://exa mple/", "", nil].each do |referer|
            location = timeout_redirect(method: "POST", referer:)

            assert_equal HOST, location.host, referer.inspect
            assert_equal "/users/sign_in", location.path, referer.inspect
          end
        end

        test "a same-host Referer keeps returning the citizen to where they were" do
          location = timeout_redirect(method: "PATCH", referer: "http://#{HOST}/processes/budzet/f/3/?filter=open")

          assert_equal HOST, location.host
          assert_equal "/processes/budzet/f/3/", location.path
          assert_equal "filter=open", location.query
        end

        # Warden records attempted_path from the raw request line, so a GET for
        # `//evil.example/x` must not become `Location: //evil.example/x`.
        test "a timed-out GET for a protocol-relative path stays on this host" do
          { "//evil.example/x" => "/x", "///evil.example/x" => "/evil.example/x" }.each do |attempted_path, expected|
            location = timeout_redirect(method: "GET", referer: nil, attempted_path:)

            assert_equal HOST, location.host, attempted_path
            assert_equal expected, location.path, attempted_path
          end
        end

        test "a timed-out GET keeps a filtered list path and its query" do
          location = timeout_redirect(method: "GET", referer: nil, attempted_path: "/processes/budzet/f/3/?filter[with_any_state][]=open")

          assert_equal [HOST, "/processes/budzet/f/3/"], [location.host, location.path]
          assert_equal "filter[with_any_state][]=open", location.query
        end

        test "a timed-out GET still returns to the attempted path and other failures go to sign-in" do
          get_location = timeout_redirect(method: "GET", referer: "https://evil.example/", attempted_path: "/account")
          assert_equal [HOST, "/account"], [get_location.host, get_location.path]

          other = failure_response(method: "POST", referer: "https://evil.example/", message: :invalid)
          assert_equal [HOST, "/users/sign_in"], [URI(other.fetch("Location")).host, URI(other.fetch("Location")).path]
        end

        private

        def timeout_redirect(method:, referer:, attempted_path: "/account")
          headers = failure_response(method:, referer:, message: :timeout, attempted_path:)
          URI(headers.fetch("Location"))
        end

        def failure_response(method:, referer:, message:, attempted_path: "/account")
          env = Rails.application.env_config.merge(Rack::MockRequest.env_for("http://#{HOST}#{attempted_path}", method:))
          env["HTTP_REFERER"] = referer unless referer.nil?
          env["warden.options"] = { scope: :user, message:, attempted_path: }
          env["warden"] = Struct.new(:message).new(nil) # Devise reads warden.message first
          env["action_dispatch.request.formats"] = [Mime[:html]]
          # A real (memory-backed) session: the GET branch stores the attempted
          # path and the timeout branch writes the flash.
          app = ActionDispatch::Session::CacheStore.new(StallFreeFailureApp, cache: ActiveSupport::Cache::MemoryStore.new, key: "_devise_advisory_test")
          status, headers, = app.call(env).to_a

          assert_equal 302, status
          headers
        end
      end

      # End to end through the middleware stack, Warden's timeoutable hook and
      # the real RandomStalling (which stalls up to five seconds): HAZARDS §4,
      # an override only proven at unit level is not proven on a live request.
      class DeviseTimeoutRedirectRequestTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        # Keep the Devise timeout below the generated host's cookie lifetime,
        # so Warden reports :timeout while the authenticated cookie still exists.
        setup do
          @devise_timeout_in = ::Devise.timeout_in
          ::Devise.timeout_in = 1.minute
        end

        teardown do
          ::Devise.timeout_in = @devise_timeout_in
        end

        test "a session that times out on PUT /account with a foreign Referer stays on this host" do
          organization = create_organization
          host! organization.host
          user = FactoryBot.create(:user, :confirmed, organization:)
          sign_in user
          get "/account"
          assert_redirected_to Decidim::Bih.public_path("moj-nalog")
          assert_equal user.id, request.env.fetch("warden").user(:user)&.id
          assert_equal 1.minute, user.timeout_in
          assert_operator Rails.application.config.session_options.fetch(:expire_after), :>, 2.minutes

          travel(2.minutes) do
            put "/account", params: { user: { name: "Promjena" } },
                            headers: { "HTTP_REFERER" => "https://evil.example/phish?x=1" }
          end

          assert_response :redirect
          location = URI(response.location)
          assert_equal [organization.host, "/phish", "x=1"], [location.host, location.path, location.query]
          assert flash[:timedout]
        end
      end
    end
  end
end
