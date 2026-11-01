# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Decidim::Bih::Registration::PendingAccess is the ONLY thing standing
      # between "a citizen who has registered but not yet proven the phone"
      # and the pending page: the citizen is NOT signed in until the verify
      # link is consumed or the code is confirmed (spec 5.4.3 / 5.4.4).
      #
      # Two token purposes, one difference that matters: the token minted into
      # the registering browser's own session MAY hand that session over once
      # the phone confirms; the token mailed to an address nobody has proven
      # NEVER may. The e-mail link verifies neither the phone nor the address,
      # so it can only ever show the page.
      class RegistrationPendingAccessTest < ActiveSupport::TestCase
        PA = Decidim::Bih::Registration::PendingAccess

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(user: @citizen, name: "sms", unique_id: "u-#{@citizen.id}", granted_at: nil)
        end

        test "a session token resolves with hand-off rights, an e-mail token without" do
          assert_equal({ user: @citizen, handoff: true }, PA.resolve(PA.mint_session(@citizen), organization: @organization))
          assert_equal({ user: @citizen, handoff: false }, PA.resolve(PA.mint_email(@citizen), organization: @organization))
        end

        test "tokens do not resolve for another organization, or after the sms grant" do
          token = PA.mint_session(@citizen)
          assert_nil PA.resolve(token, organization: create_organization)
          Decidim::Authorization.find_by(user: @citizen).update!(granted_at: Time.current)
          assert_nil PA.resolve(token, organization: @organization)
          assert_equal({ user: @citizen, handoff: true }, PA.resolve(token, organization: @organization, allow_verified: true), "status polling may still see a just-verified user")
        end

        test "a blocked or deleted account never resolves, not even for status polling" do
          token = PA.mint_session(@citizen)
          @citizen.update!(blocked: true, blocked_at: Time.current)
          assert_nil PA.resolve(token, organization: @organization)
          assert_nil PA.resolve(token, organization: @organization, allow_verified: true)

          @citizen.update!(blocked: false, blocked_at: nil, deleted_at: Time.current)
          assert_nil PA.resolve(token, organization: @organization)
          assert_nil PA.resolve(token, organization: @organization, allow_verified: true)
        end

        test "an expired token does not resolve" do
          token = PA.mint_session(@citizen)
          travel 8.days do
            assert_nil PA.resolve(token, organization: @organization)
          end
        end

        test "a blank, garbled or foreign-purpose token never resolves" do
          assert_nil PA.resolve(nil, organization: @organization)
          assert_nil PA.resolve("", organization: @organization)
          assert_nil PA.resolve("not-a-signed-id", organization: @organization)
          assert_nil PA.resolve(@citizen.signed_id(purpose: :password_reset, expires_in: 7.days), organization: @organization)
          assert_nil PA.resolve(PA.mint_session(@citizen), organization: nil)
        end

        test "an e-mail token never confers the session hand-off, whatever else is true" do
          email_token = PA.mint_email(@citizen)
          assert_equal false, PA.resolve(email_token, organization: @organization)[:handoff]

          Decidim::Authorization.find_by(user: @citizen).update!(granted_at: Time.current)
          assert_equal false, PA.resolve(email_token, organization: @organization, allow_verified: true)[:handoff]
        end

        test "hand-off window follows the verify link plus five minutes" do
          refute PA.handoff_window_open?(@citizen)
          Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "verify", phone: "+38765123456")
          assert PA.handoff_window_open?(@citizen)
          travel Decidim::Bih::LoginToken::VERIFY_TTL + PA::HANDOFF_GRACE + 1.minute do
            refute PA.handoff_window_open?(@citizen)
          end
        end

        # The hand-off happens right AFTER the verify token is consumed, so a
        # window that only counted live tokens (`where(consumed_at: nil)`)
        # would be shut at exactly the moment Task 5b needs it open. The
        # "two minutes past expiry" case bounds the grace from below too: the
        # token itself is dead by then, and it is HANDOFF_GRACE alone keeping
        # the window open there.
        test "the hand-off window survives consuming the verify token, and the grace bounds it" do
          raw = Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "verify", phone: "+38765123456")
          assert Decidim::Bih::LoginToken.consume!(raw:, organization: @organization, purpose: "verify")
          assert PA.handoff_window_open?(@citizen), "consuming the token is what opens the window, not what closes it"

          travel Decidim::Bih::LoginToken::VERIFY_TTL + 2.minutes do
            assert PA.handoff_window_open?(@citizen), "expired at the link lifetime, still inside the five-minute grace"
          end
          travel Decidim::Bih::LoginToken::VERIFY_TTL + PA::HANDOFF_GRACE + 1.minute do
            refute PA.handoff_window_open?(@citizen)
          end
        end

        test "pending? is true only while the sms authorization exists and is ungranted" do
          assert PA.pending?(@citizen)

          Decidim::Authorization.find_by(user: @citizen).update!(granted_at: Time.current)
          refute PA.pending?(@citizen)

          Decidim::Authorization.find_by(user: @citizen).destroy!
          refute PA.pending?(@citizen)
        end
      end
    end
  end
end
