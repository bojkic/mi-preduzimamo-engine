# frozen_string_literal: true

require_relative "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The week an unconfirmed one-step registration gets, and what the daily
      # sweep does with it. In the harness rather than the unit suite because
      # every decision reads real users, authorizations and tokens.
      class RegistrationPendingLifecycleTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper
        include ActionMailer::TestHelper

        LIFECYCLE = Decidim::Bih::Registration::PendingLifecycle
        PHONE = "+38765123456"

        setup do
          @organization = create_organization
        end

        # A one-step registration as the sweep finds it: an active account
        # nobody has signed into, with a pending `sms` row.
        def stub!(created_at: Time.current, email: "stub-#{SecureRandom.hex(4)}@example.org")
          user = FactoryBot.create(:user, :confirmed, organization: @organization, email:, sign_in_count: 0)
          user.update_column(:created_at, created_at) # rubocop:disable Rails/SkipsModelValidations
          Decidim::Authorization.create!(
            user:, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE),
            granted_at: nil,
            verification_metadata: { "code_sent_at" => created_at.iso8601, "verification_code" => "123456" }
          )
          user
        end

        def grant!(user)
          Decidim::Authorization.find_by(user:, name: "sms").update!(granted_at: Time.current, verification_metadata: {})
        end

        test "retention is seven days and the resume e-mail token lives exactly as long" do
          assert_equal 7.days, LIFECYCLE::RETENTION
          assert_equal 5.days, LIFECYCLE::SECOND_REMINDER_AT
          assert_equal LIFECYCLE::RETENTION, Decidim::Bih::Registration::PendingAccess::TTL
        end

        test "a fresh one-step registration is a stub" do
          assert LIFECYCLE.stub?(stub!)
        end

        test "a granted phone, a sign-in, a role, points or a missing sms row all disqualify" do
          granted = stub!
          grant!(granted)
          refute LIFECYCLE.stub?(granted)

          signed_in = stub!
          signed_in.update_column(:sign_in_count, 1) # rubocop:disable Rails/SkipsModelValidations
          refute LIFECYCLE.stub?(signed_in)

          admin = stub!
          admin.update_column(:admin, true) # rubocop:disable Rails/SkipsModelValidations
          refute LIFECYCLE.stub?(admin)

          rich = stub!
          Decidim::Bih::Goodwill::Ledger.new.award(rich, 10, reason: "rails_harness_seed")
          refute LIFECYCLE.stub?(rich)

          plain = FactoryBot.create(:user, :confirmed, organization: @organization, sign_in_count: 0)
          refute LIFECYCLE.stub?(plain), "no pending sms row means this was never a one-step registration"
          refute LIFECYCLE.stub?(nil)
        end

        test "DestroyStub removes the account and its rows; refuses anything that is not a stub; reports a vanished row" do
          user = stub!
          Decidim::Bih::LoginToken.issue!(user:, purpose: "verify", phone: PHONE)
          user_id = user.id
          stale_copy = Decidim::User.find(user_id)

          assert_equal :destroyed, Decidim::Bih::Registration::DestroyStub.call(user)
          assert_nil Decidim::User.find_by(id: user_id)
          assert_empty Decidim::Bih::LoginToken.where(decidim_user_id: user_id)
          assert_empty Decidim::Authorization.where(decidim_user_id: user_id)

          verified = stub!
          grant!(verified)
          assert_equal :refused, Decidim::Bih::Registration::DestroyStub.call(verified)
          assert Decidim::User.exists?(verified.id)

          assert_equal :gone, Decidim::Bih::Registration::DestroyStub.call(stale_copy),
                       "the other caller already removed it: not an error, just gone"
        end

        test "the sweep sends the final notice once, from day 5, only to stubs" do
          due = stub!(created_at: 5.days.ago - 1.minute)
          early = stub!(created_at: 4.days.ago)

          counts = nil
          assert_emails(1) { counts = LIFECYCLE.sweep(organization: @organization, dry_run: false) }
          assert_equal 1, counts[:reminded]
          assert due.reload.extended_data[LIFECYCLE::FINAL_NOTICE_SENT_AT_KEY].present?
          assert_nil early.reload.extended_data[LIFECYCLE::FINAL_NOTICE_SENT_AT_KEY]

          assert_emails(0) { LIFECYCLE.sweep(organization: @organization, dry_run: false) }
        end

        test "a dry run counts but sends nothing and writes no marker" do
          due = stub!(created_at: 6.days.ago)
          counts = nil
          assert_emails(0) { counts = LIFECYCLE.sweep(organization: @organization, dry_run: true) }
          assert counts[:dry_run]
          assert_equal 1, counts[:reminded]
          assert_nil due.reload.extended_data[LIFECYCLE::FINAL_NOTICE_SENT_AT_KEY]
        end

        test "the final notice carries the resume link and the name, never the number or the code" do
          user = stub!(created_at: 5.days.ago)
          LIFECYCLE.sweep(organization: @organization, dry_run: false)
          mail = ActionMailer::Base.deliveries.last
          body = mail.html_part.body.to_s
          assert_includes mail.subject, I18n.t("decidim.bih.registration_mailer.final_notice.subject", locale: :sr)
          assert_includes body, "pending_token="
          assert_includes body, user.name
          refute_includes body, PHONE
          refute_includes body, "123456"
        end

        test "the sweep deletes a stub on day 7, keeps one with a live link, and records the run" do
          gone = stub!(created_at: 7.days.ago - 1.minute)
          kept = stub!(created_at: 8.days.ago)
          Decidim::Bih::LoginToken.issue!(user: kept, purpose: "verify", phone: "+38765999999")
          verified = stub!(created_at: 9.days.ago)
          grant!(verified)
          gone_email = gone.email

          counts = LIFECYCLE.sweep(organization: @organization, dry_run: false)

          assert_equal 1, counts[:deleted]
          assert_equal 1, counts[:skipped_live_link]
          assert_nil Decidim::User.find_by(id: gone.id)
          assert Decidim::User.exists?(kept.id)
          assert Decidim::User.exists?(verified.id)

          event = Decidim::Bih::OperatorAuditEvent.where(event_type: "registration_pending_swept").last
          assert_equal 1, event.metadata["deleted"]
          assert_equal false, event.metadata["dry_run"]
          refute_includes event.metadata.to_json, gone_email
        end

        test "an expired link no longer protects a stub" do
          stub = stub!(created_at: 8.days.ago)
          Decidim::Bih::LoginToken.issue!(user: stub, purpose: "verify", phone: "+38765999999")
          Decidim::Bih::LoginToken.where(user: stub).update_all(expires_at: 1.minute.ago) # rubocop:disable Rails/SkipsModelValidations

          counts = LIFECYCLE.sweep(organization: @organization, dry_run: false)
          assert_equal 1, counts[:deleted]
          assert_nil Decidim::User.find_by(id: stub.id)
        end

        test "pending_scope lists only this organization's stubs, oldest first" do
          old = stub!(created_at: 8.days.ago)
          young = stub!
          elsewhere = create_organization
          FactoryBot.create(:user, :confirmed, organization: elsewhere, sign_in_count: 0)

          assert_equal [old.id, young.id], LIFECYCLE.pending_scope(@organization).pluck(:id)
        end
      end
    end
  end
end
