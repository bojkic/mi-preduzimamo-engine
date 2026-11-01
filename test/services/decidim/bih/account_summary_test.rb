# frozen_string_literal: true

require "test_helper"
require "active_support/core_ext/object/blank"
require "decidim/bih"
require_relative "../../../../app/services/decidim/bih/account_summary"

module Decidim
  module Bih
    class AccountSummaryTest < Minitest::Test
      TestSummary = Class.new(AccountSummary) do
        def initialize(sms:, postal:, phone_recorded: true)
          @sms = sms
          @postal = postal
          @phone_recorded = phone_recorded
          super(organization: Object.new, user: Object.new)
        end

        def email_confirmed?
          true
        end

        def komsiluk_assigned?
          true
        end

        def sms_verified?
          @sms
        end

        def postal_verified?
          @postal
        end

        def phone_number_saved?
          @phone_recorded
        end

        def postal_status
          @postal ? :confirmed : :not_requested
        end

        def report_count
          1
        end

        def active_volunteer_signup_count
          0
        end

        def approved_volunteer_hours
          0
        end
      end

      def test_phone_alone_completes_account_verification
        summary = TestSummary.new(sms: true, postal: false)

        assert summary.account_verification_complete?
        assert_equal 4, summary.required_steps_count
        assert_equal 100, summary.completion_percent
        assert_step summary, :phone, state: :done, text_key: "phone.done"
        assert_step summary, :postal, state: :optional, text_key: "postal.optional"
      end

      def test_postal_letter_alone_completes_account_verification
        summary = TestSummary.new(sms: false, postal: true)

        assert summary.account_verification_complete?
        assert_equal 4, summary.required_steps_count
        assert_equal 100, summary.completion_percent
        assert_step summary, :phone, state: :optional, text_key: "phone.optional"
        assert_step summary, :postal, state: :done, text_key: "postal.done"
      end

      def test_verification_is_one_required_step_when_neither_method_is_complete
        summary = TestSummary.new(sms: false, postal: false)

        refute summary.account_verification_complete?
        assert_equal 4, summary.required_steps_count
        assert_equal 75, summary.completion_percent
        assert_step summary, :phone, state: :todo, text_key: "phone.todo"
        assert_step summary, :postal, state: :todo, text_key: "postal.todo"
      end

      # The "sms" authorization was granted, but PhoneVerification::Complete's
      # phone write is best-effort and can fail independently of the grant
      # (see its comment) — this is exactly that gap. The account stays
      # verified (sms_verified? alone still satisfies
      # account_verification_complete?), but the phone step itself must nudge
      # the citizen to re-confirm rather than claim :done, since nothing can
      # be sent to a number that was never saved.
      def test_phone_granted_without_a_saved_number_asks_to_reverify
        summary = TestSummary.new(sms: true, postal: false, phone_recorded: false)

        assert summary.account_verification_complete?
        assert_step summary, :phone, state: :reverify, text_key: "phone.reverify"

        step = summary.setup_steps.find { |candidate| candidate.key == :phone }
        assert_equal :phone_verification, step.href_key
      end

      # Inviting is an always-open invitation, never a box a citizen is failing
      # to tick. It must stay OUT of required_steps: putting it in would move
      # every existing citizen's completion percentage backwards overnight and
      # tell people who finished their account that they had not.
      def test_the_invite_step_is_offered_but_never_required
        summary = TestSummary.new(sms: true, postal: false)

        assert_step summary, :invite, state: :optional, text_key: "invite.todo"
        assert_equal 4, summary.required_steps_count
        assert_equal 100, summary.completion_percent

        refute_includes summary.send(:required_steps).map(&:key), :invite
      end

      def test_the_invite_step_points_at_the_invite_tab
        step = TestSummary.new(sms: true, postal: false).setup_steps.find { |s| s.key == :invite }

        assert_equal :invite, step.href_key
      end

      private

      def assert_step(summary, key, state:, text_key:)
        step = summary.setup_steps.find { |candidate| candidate.key == key }

        refute_nil step
        assert_equal state, step.state
        assert_equal text_key, step.text_key
      end
    end
  end
end
