# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # SOURCES gains "registration" so the one-step /registracija form
      # (delivery D) can assign a komsiluk at sign-up time, before the phone is
      # verified. This locks two things down together, because either one
      # breaking silently changes the points schedule:
      #   - "registration" is an accepted assignment source (validation).
      #   - a registration-sourced komsiluk is paid by the SAME award hook as
      #     a dropdown pick once the phone is verified (registration total 20
      #     = verification welcome 10 + komsiluk_selected 10) -- it must never
      #     be treated like "postal", which authorization_referral_override.rb
      #     deliberately skips (see awards_after_verification_test.rb).
      class CitizenProfileRegistrationSourceTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        AWARD_JOB = Decidim::Bih::Goodwill::GoodwillAwardJob

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          # No :local_area factory in this harness -- build the row directly,
          # exactly as rails_test/onboarding_next_step_test.rb does.
          @komsiluk = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id,
            kind: "komsiluk",
            slug: "k-#{@citizen.id}",
            name: { "sr" => "Test komšiluk" }
          )
        end

        def balance
          Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen).reload.balance
        end

        def grant_sms!
          Decidim::Authorization.create!(
            user: @citizen, name: "sms", unique_id: "u-#{@citizen.id}", granted_at: Time.current
          )
        end

        def assign_komsiluk!(source:)
          profile = Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization)
          profile.assign_komsiluk!(@komsiluk, source:)
          profile
        end

        test "registration is an accepted assignment source" do
          profile = assign_komsiluk!(source: "registration")

          assert profile.reload.assigned?
          assert_equal "registration", profile.source
        end

        test "a registration-sourced komsiluk pays the komsiluk award on verification (total 20)" do
          assign_komsiluk!(source: "registration")

          perform_enqueued_jobs(only: AWARD_JOB) { grant_sms! }

          assert_equal 20, balance,
                       "registration total is the verification welcome (10) plus the komsiluk award (10)"
        end

        test "a postal-sourced komsiluk still pays nothing on verification" do
          assign_komsiluk!(source: "postal")

          perform_enqueued_jobs(only: AWARD_JOB) { grant_sms! }

          assert_equal 10, balance, "postal is skipped by the award hook; only the verification welcome is paid"
        end
      end
    end
  end
end
