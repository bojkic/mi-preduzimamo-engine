# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Spec 9.1 (Sybil gate): the komšiluk award and the welcome notification
      # are earned by a VERIFIED phone, not by an e-mail address. A citizen who
      # picks a komšiluk before verifying earns nothing at pick time; the first
      # granted `sms` authorization pays it.
      #
      # The welcome half is one assertion of a pair: this file proves it FIRES
      # at the sms grant, and rails_test/email_confirmation_test.rb ("devise
      # after_confirmation records the address and skips the welcome when
      # phone-first") proves it does NOT fire at e-mail confirmation. Change one
      # and check the other, or a phone-first host silently sends two welcomes
      # or none.
      class AwardsAfterVerificationTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveJob::TestHelper

        # Scoped to GoodwillAwardJob on purpose — never a bare
        # `perform_enqueued_jobs do`. Every ledger award also fires Decidim's
        # :events chain (EventPublisherJob -> EmailNotificationGeneratorJob),
        # and actually performing the mail job would have premailer-rails fetch
        # the mailer layout's CSS over real HTTP from this run's fake host
        # (rails-test-<hex>.lvh.me), where nothing is listening — see the same
        # note in rails_test/launch_invitation_trigger_test.rb. The points are
        # what is under test here, and they are all carried by this one job.
        AWARD_JOB = Decidim::Bih::Goodwill::GoodwillAwardJob

        WELCOME_EVENT = "decidim.events.core.welcome_notification"

        setup do
          @organization = create_organization
          @organization.update!(send_welcome_notification: true)
          host! @organization.host
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          # No :local_area factory in this harness — build the row directly,
          # exactly as rails_test/onboarding_next_step_test.rb does.
          @komsiluk = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id,
            kind: "komsiluk",
            slug: "k-#{@citizen.id}",
            name: { "sr" => "Test komšiluk" }
          )
          Decidim::Bih.phone_first_registration = true
        end

        teardown { Decidim::Bih.phone_first_registration = false }

        def balance
          Decidim::Bih::Goodwill::Ledger.new.account_for(@citizen).reload.balance
        end

        def grant_sms!
          Decidim::Authorization.create!(
            user: @citizen, name: "sms", unique_id: "u-#{@citizen.id}", granted_at: Time.current
          )
        end

        # No verification_metadata, so update_komsiluk_from_postal_if_granted
        # short-circuits on :no_address and never geocodes — the postal komšiluk
        # is set up explicitly by assign_komsiluk! instead.
        def grant_postal!
          Decidim::Authorization.create!(
            user: @citizen, name: "postal_letter", unique_id: "p-#{@citizen.id}", granted_at: Time.current
          )
        end

        def assign_komsiluk!(source:)
          profile = Decidim::Bih::CitizenProfile.for_user(@citizen, organization: @organization)
          profile.assign_komsiluk!(@komsiluk, source:)
          profile
        end

        def komsiluk_award_transactions
          Decidim::Bih::Goodwill::Transaction.where(
            idempotency_key: "komsiluk_selected:#{@citizen.id}"
          ).count
        end

        # A renewal: granted_at changes again, from a timestamp rather than from
        # nil. This is the case granted_at_transitioned_from_nil? exists to
        # exclude, so it is a sharper probe than a bare touch — the column
        # really is dirty, and the guard is the only thing stopping a re-award.
        def regrant_sms!
          Decidim::Authorization.find_by(user: @citizen, name: "sms")
                                .update!(granted_at: 1.minute.from_now)
        end

        def choose_komsiluk!
          patch Decidim::Bih.public_path("komsiluk"),
                params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
        end

        # Count the WELCOME publications specifically, never bare
        # EventPublisherJob enqueues: granting `sms` also sets the
        # :verified_citizen gamification badge, and Decidim publishes a
        # badge-earned event for that through the very same job. A plain
        # `assert_enqueued_with(job: Decidim::EventPublisherJob)` therefore
        # passes with no welcome code at all — verified on the RED run of this
        # file. EventsManager.publish puts the event NAME in the job's first
        # argument, so match on that.
        def enqueued_welcome_publications
          enqueued_jobs.count do |job|
            job[:job] == Decidim::EventPublisherJob && job[:args].first == WELCOME_EVENT
          end
        end

        test "choosing a komsiluk before verification earns nothing; verification then pays both awards once" do
          sign_in @citizen
          perform_enqueued_jobs(only: AWARD_JOB) { choose_komsiluk! }

          assert_equal 0, balance, "an unverified citizen's komšiluk choice earns nothing"

          perform_enqueued_jobs(only: AWARD_JOB) { grant_sms! }

          assert_equal 20, balance, "verification pays the verification welcome AND the deferred komšiluk award"
          assert_equal 1, komsiluk_award_transactions,
                       "the controller path and the grant path collapse to one ledger transaction"

          perform_enqueued_jobs(only: AWARD_JOB) { regrant_sms! }

          assert_equal 20, balance, "re-grants never double-award"
        end

        test "choosing a komsiluk after verification pays the komsiluk award immediately" do
          perform_enqueued_jobs(only: AWARD_JOB) { grant_sms! }

          assert_equal 10, balance, "verification alone is the 10-point welcome"

          sign_in @citizen
          perform_enqueued_jobs(only: AWARD_JOB) { choose_komsiluk! }

          assert_equal 20, balance, "an already-verified citizen is paid by the picker itself"
        end

        test "verification pays no komsiluk award when no komsiluk was chosen" do
          perform_enqueued_jobs(only: AWARD_JOB) { grant_sms! }

          assert_equal 10, balance, "nothing is paid for a komšiluk that was never chosen"
        end

        # Both new hooks are pinned to name == "sms". A postal_letter grant is a
        # real verification that assigns a komšiluk from the citizen's address —
        # neither of those is the phone-first "you are in" moment, and neither is
        # a choice, so it must pay nothing and welcome nobody. The later sms
        # grant then welcomes, but still does not pay for the postal komšiluk.
        test "a postal grant neither welcomes nor pays, and a later sms grant welcomes without paying" do
          profile = assign_komsiluk!(source: "postal")

          # Preconditions, so a zero below can never mean "the setup silently
          # did nothing". Together with the dropdown case above — same citizen
          # shape, same hooks, one transaction — these pin the guard to `source`
          # and nothing else.
          assert profile.assigned?
          assert_equal "postal", profile.source

          perform_enqueued_jobs(only: AWARD_JOB) { grant_postal! }

          assert_equal 0, enqueued_welcome_publications, "only an sms grant is the phone-first welcome moment"
          assert_equal 0, komsiluk_award_transactions, "a postal address assignment is not a choice"

          perform_enqueued_jobs(only: AWARD_JOB) { grant_sms! }

          assert_equal 0, komsiluk_award_transactions,
                       "verifying by phone later still does not pay for a komšiluk the citizen never picked"
          assert_equal 1, enqueued_welcome_publications, "the sms grant welcomes exactly once"
        end

        test "the welcome notification is published on the first sms grant" do
          assert_enqueued_with(job: Decidim::EventPublisherJob) { grant_sms! }

          assert_equal 1, enqueued_welcome_publications,
                       "the phone, not the e-mail, is the moment a phone-first citizen is welcomed"
        end

        test "the welcome notification is published only once, not again on a re-grant" do
          grant_sms!
          regrant_sms!

          assert_equal 1, enqueued_welcome_publications, "re-grants never re-welcome"
        end

        test "no welcome notification is published on a host that is not phone-first" do
          Decidim::Bih.phone_first_registration = false
          grant_sms!

          assert_equal 0, enqueued_welcome_publications,
                       "with the switch off core still welcomes at e-mail confirmation"
        end

        test "no welcome notification is published when the organization does not send one" do
          @organization.update!(send_welcome_notification: false)
          grant_sms!

          assert_equal 0, enqueued_welcome_publications
        end
      end
    end
  end
end
