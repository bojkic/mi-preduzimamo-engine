# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/numeric/time"
require "active_support/time"
require_relative "../../../../../app/services/decidim/bih/goodwill/referrals"

module Decidim
  module Bih
    module Goodwill
      class ReferralsTest < Minitest::Test
        Person = Struct.new(:id, :organization, :created_at, keyword_init: true)

        class ReferralRecord
          attr_reader :referrer, :invitee_id
          attr_accessor :referrer_id, :status

          def initialize(referrer:, invitee_id:)
            @referrer = referrer
            @referrer_id = referrer.id
            @invitee_id = invitee_id
            @status = "pending"
          end

          def reload
            self
          end
        end

        class ReferralModel
          class << self
            def reset!(referral)
              @referral = referral
            end

            def find_by(invitee_id:)
              @referral if @referral&.invitee_id == invitee_id
            end
          end
        end

        def setup
          @previous_zone_default = Time.zone_default
          Time.zone_default = ActiveSupport::TimeZone["UTC"]
          @organization = Object.new
          @referrer = Person.new(id: 3, organization: @organization)
          @invitee = Person.new(id: 12, organization: @organization)
          @referral = ReferralRecord.new(referrer: @referrer, invitee_id: @invitee.id)
          ReferralModel.reset!(@referral)
        end

        def teardown
          Time.zone_default = @previous_zone_default
        end

        # The database-backed settlement suite verifies payment order, the
        # eligibility/delay gates, and monthly carryover. This facade must drain
        # the inviter's queue and report the persisted result for this invitee.
        def test_reward_drains_the_inviter_queue_and_returns_the_settled_referral
          calls = []
          settle = lambda do |referrer|
            calls << referrer
            @referral.status = "rewarded"
            [@referral]
          end
          result = with_collaborators do
            Referrals.stub(:settle_queue, settle) { Referrals.reward(@invitee) }
          end

          assert_same @referral, result
          assert_equal [@referrer], calls
        end

        def test_reward_keeps_the_pending_result_when_the_queue_cannot_yet_pay
          calls = []
          settle = ->(referrer) { calls << referrer; [] }
          result = with_collaborators do
            Referrals.stub(:settle_queue, settle) { Referrals.reward(@invitee) }
          end

          assert_equal :pending_activity, result
          assert_equal [@referrer], calls
          assert_equal "pending", @referral.status
        end

        def test_reward_does_not_drain_the_queue_for_an_already_paid_referral
          @referral.status = "rewarded"
          with_collaborators do
            Referrals.stub(:settle_queue, ->(*) { flunk "paid referral must not resettle" }) do
              assert_nil Referrals.reward(@invitee)
            end
          end
        end

        def test_reward_without_an_attribution_is_a_no_op
          ReferralModel.reset!(nil)
          with_collaborators do
            Referrals.stub(:settle_queue, ->(*) { flunk "missing referral must not settle" }) do
              assert_nil Referrals.reward(@invitee)
              assert_nil Referrals.reward(nil)
            end
          end
        end

        # ---------------------------------------------- attribute_from_session

        # The one place a session-carried referral code is spent, shared by the
        # Warden hook and the one-step registration's POST. What matters here
        # is which sessions it REFUSES.

        def session_with(code: "komsija", captured_at: Time.current)
          { "goodwill_ref" => code }.tap do |session|
            session["goodwill_ref_at"] = captured_at.utc.iso8601 if captured_at
          end
        end

        def attributing(&)
          attempts = []
          record = ->(**kwargs) { attempts.push(kwargs) && :attributed }
          result = Referrals.stub(:attribute, record, &)
          [result, attempts]
        end

        def test_attribute_from_session_attributes_a_code_captured_inside_the_window
          session = session_with(captured_at: 2.hours.ago)
          invitee = Person.new(id: 12, organization: @organization, created_at: Time.current)

          result, attempts = attributing { Referrals.attribute_from_session(session, invitee) }

          assert_equal :attributed, result
          assert_equal [{ invitee:, code: "komsija" }], attempts
          assert_empty session, "a spent code is forgotten, so a second call cannot spend it twice"
        end

        def test_attribute_from_session_refuses_a_code_captured_more_than_a_day_ago
          session = session_with(captured_at: 25.hours.ago)
          invitee = Person.new(id: 12, organization: @organization, created_at: Time.current)

          result, attempts = attributing { Referrals.attribute_from_session(session, invitee) }

          assert_nil result
          assert_empty attempts, "the window is closed, so nothing is attributed"
          assert_empty session, "and the stale keys are dropped rather than left to be re-read"
        end

        def test_attribute_from_session_refuses_an_account_that_existed_before_the_click
          session = session_with(captured_at: 1.hour.ago)
          invitee = Person.new(id: 12, organization: @organization, created_at: 3.days.ago)

          result, attempts = attributing { Referrals.attribute_from_session(session, invitee) }

          assert_nil result
          assert_empty attempts, "an account older than the click was never invited by it"
        end

        def test_attribute_from_session_falls_back_to_the_legacy_recency_guard
          minutes_old = Person.new(id: 12, organization: @organization, created_at: 2.minutes.ago)
          hours_old = Person.new(id: 13, organization: @organization, created_at: 2.hours.ago)

          fresh, fresh_attempts = attributing do
            Referrals.attribute_from_session(session_with(captured_at: nil), minutes_old)
          end
          stale, stale_attempts = attributing do
            Referrals.attribute_from_session(session_with(captured_at: nil), hours_old)
          end

          assert_equal :attributed, fresh
          assert_equal 1, fresh_attempts.size
          assert_nil stale, "with no capture time an old account is not accepted blindly"
          assert_empty stale_attempts
        end

        def test_attribute_from_session_is_a_no_op_once_the_keys_are_gone
          invitee = Person.new(id: 12, organization: @organization, created_at: Time.current)

          result, attempts = attributing { Referrals.attribute_from_session({}, invitee) }

          assert_nil result
          assert_empty attempts
        end

        private

        def with_collaborators(&)
          with_constant(Decidim::Bih::Goodwill, :Referral, ReferralModel, &)
        end

        def with_constant(parent, name, value)
          old_defined = parent.const_defined?(name, false)
          old_value = parent.const_get(name, false) if old_defined
          parent.send(:remove_const, name) if old_defined
          parent.const_set(name, value)
          yield
        ensure
          parent.send(:remove_const, name) if parent.const_defined?(name, false)
          parent.const_set(name, old_value) if old_defined
        end
      end
    end
  end
end
