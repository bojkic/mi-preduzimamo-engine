# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class EmailConfirmationTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        # Decidim::EventsManager.publish goes through
        # ActiveSupport::Notifications; the subscriber core registers in
        # `decidim_core.notifications` enqueues Decidim::EventPublisherJob.
        # That job is what the welcome notification actually enqueues here —
        # EmailNotificationGeneratorJob is only enqueued once EventPublisherJob
        # *performs*, which the recording :test adapter never does. Asserting on
        # EmailNotificationGeneratorJob would therefore pass vacuously, so the
        # welcome is observed at its first hop instead.
        WELCOME_JOB = Decidim::EventPublisherJob

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        teardown do
          Decidim::Bih.phone_first_registration = false
          Decidim::Bih.phone_first_registration_since = nil
        end

        test "an account confirmed before the cutoff counts as e-mail confirmed" do
          Decidim::Bih.phone_first_registration_since = 1.day.from_now.utc.to_s

          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen)
        end

        test "an account confirmed after the cutoff is not e-mail confirmed" do
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s

          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen)
        end

        # A nil cutoff is "no cutoff" only for a stock host. Off, every
        # confirmed_at came from the Devise link and is proof; on, confirmed_at
        # comes from skip_confirmation! at sign-up and must prove nothing —
        # otherwise a host that sets the flag but forgets the date hands a
        # proven e-mail to every account it has.
        test "without a cutoff a confirmed account is proven while phone-first is off" do
          Decidim::Bih.phone_first_registration = false
          Decidim::Bih.phone_first_registration_since = nil

          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen)
        end

        test "without a cutoff nothing is grandfathered once phone-first is on" do
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih.phone_first_registration_since = nil

          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen)
        end

        test "marking confirms exactly the current address" do
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)

          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload)

          @citizen.update_columns(email: "drugi-#{@citizen.id}@example.org") # rubocop:disable Rails/SkipsModelValidations

          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen.reload), "a changed address loses the confirmation"
        end

        # Half of a pair: rails_test/awards_after_verification_test.rb proves the
        # welcome then FIRES on the first granted `sms` instead. Change one and
        # check the other.
        test "devise after_confirmation records the address and skips the welcome when phone-first" do
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s
          @organization.update!(send_welcome_notification: true)
          fresh = FactoryBot.create(:user, organization: @organization) # unconfirmed

          assert_no_enqueued_jobs(only: WELCOME_JOB) do
            fresh.confirm
          end
          assert Decidim::Bih::EmailConfirmation.confirmed?(fresh.reload)
        end

        # Password recovery (spec 9.2) must follow the address the citizen last
        # PROVED, not the one they merely typed. Decidim runs Devise with
        # `config.reconfirmable = true` (decidim-core 0.31.7
        # config/initializers/devise.rb:196), so assigning a new e-mail parks it
        # in unconfirmed_email and leaves `email` alone until the link is
        # followed; `confirm` then promotes it and fires after_confirmation.
        test "devise reconfirmation records the new address, not the old one" do
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s
          old_address = @citizen.email
          new_address = "nova-#{@citizen.id}@example.org"

          @citizen.update!(email: new_address)

          assert_equal old_address, @citizen.reload.email, "reconfirmable parks the change in unconfirmed_email"
          assert_equal new_address, @citizen.unconfirmed_email
          refute Decidim::Bih::EmailConfirmation.confirmed?(@citizen), "not proven until the link is followed"

          @citizen.confirm

          assert_equal new_address, @citizen.reload.email
          assert Decidim::Bih::EmailConfirmation.confirmed?(@citizen)
          assert_equal new_address, @citizen.extended_data[Decidim::Bih::EmailConfirmation::KEY]["address"]
        end

        # Control for the test above: without it, `assert_no_enqueued_jobs`
        # could be green simply because nothing ever enqueues WELCOME_JOB in
        # this harness, and the override's early return would go unverified.
        test "devise after_confirmation still publishes the welcome when phone-first is off" do
          Decidim::Bih.phone_first_registration = false
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s
          @organization.update!(send_welcome_notification: true)
          fresh = FactoryBot.create(:user, organization: @organization) # unconfirmed

          assert_enqueued_jobs(1, only: WELCOME_JOB) do
            fresh.confirm
          end
          assert Decidim::Bih::EmailConfirmation.confirmed?(fresh.reload)
        end
      end
    end
  end
end
