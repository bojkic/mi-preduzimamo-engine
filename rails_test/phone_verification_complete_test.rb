# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class PhoneVerificationCompleteTest < ActiveSupport::TestCase
        PHONE = "+38765123456"

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def pending_authorization!(phone: PHONE, code: "123456")
          Decidim::Authorization.create!(
            user: @citizen, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            verification_metadata: { "verification_code" => code, "code_sent_at" => Time.current },
            granted_at: nil
          )
        end

        # Decidim::Authorization validates `verification_metadata` ABSENT once
        # granted (grant! clears it), so a granted row must be built the same
        # way — otherwise update! raises RecordInvalid and the test proves
        # nothing. This is also the real production shape: the 3 granted rows
        # with no stored number carry no verification code either.
        def granted_authorization!(phone: PHONE, at: 1.week.ago)
          pending_authorization!(phone:).tap do |authorization|
            authorization.update!(granted_at: at, verification_metadata: {})
          end
        end

        def complete(phone: PHONE)
          Decidim::Bih::PhoneVerification::Complete.call(user: @citizen, phone:)
        end

        test "grants a pending authorization and records the phone in both stores exactly once" do
          pending_authorization!
          Decidim::Bih::LoginToken.issue!(user: @citizen, purpose: "verify", phone: PHONE)

          result = complete
          assert result.granted?
          assert result.first_grant?
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
          assert_equal 1, Decidim::Bih::Viber::BusinessContact.where(user: @citizen).count
          assert_equal 0, Decidim::Bih::LoginToken.where(user: @citizen, purpose: "verify", consumed_at: nil).count, "live verify tokens are voided"
        end

        test "an already granted authorization without phone rows gets its rows on re-verification" do
          granted_authorization!
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)

          result = complete
          assert result.granted?
          refute result.first_grant?
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "a phone that does not match the pending authorization is refused" do
          pending_authorization!
          result = complete(phone: "+38765999999")
          refute result.granted?
          assert_equal :phone_mismatch, result.error
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        # Decidim::Verifications::Sms::ConfirmationForm validates the code's
        # presence, so a pending row whose stored code is blank makes the
        # canonical command broadcast :invalid — the one way this service can
        # reach a rejected confirmation without faking Decidim's internals.
        test "a confirmation Decidim rejects leaves the citizen ungranted and writes no phone rows" do
          pending_authorization!(code: "")

          result = complete
          refute result.granted?
          assert_equal :confirmation_rejected, result.error
          refute Decidim::Authorization.find_by(user: @citizen, name: "sms").granted?
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
          assert_equal 0, Decidim::Bih::Viber::BusinessContact.where(user: @citizen).count
        end

        test "a blocked user is never granted" do
          pending_authorization!
          @citizen.update_columns(blocked: true) # rubocop:disable Rails/SkipsModelValidations
          assert_equal :inactive_user, complete.error
        end

        test "a citizen with no sms authorization at all is refused without writing rows" do
          result = complete
          refute result.granted?
          assert_equal :no_authorization, result.error
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
          assert_equal 0, Decidim::Bih::Viber::BusinessContact.where(user: @citizen).count
        end

        test "repeating a completed verification neither double-grants nor duplicates rows" do
          pending_authorization!

          first = complete
          granted_at = Decidim::Authorization.find_by(user: @citizen, name: "sms").granted_at
          second = complete

          assert first.first_grant?
          assert second.granted?
          refute second.first_grant?
          assert_equal granted_at, Decidim::Authorization.find_by(user: @citizen, name: "sms").granted_at
          assert_equal 1, Decidim::Bih::CitizenPhoneRecord.where(user: @citizen).count
          assert_equal 1, Decidim::Bih::Viber::BusinessContact.where(user: @citizen).count
        end

        test "a blank phone is refused before any lookup" do
          pending_authorization!
          result = complete(phone: "  ")
          refute result.granted?
          assert_equal :phone_mismatch, result.error
        end

        test "the grant is committed, not rolled back by the lock block" do
          pending_authorization!

          assert complete.granted?
          assert Decidim::Authorization.find_by(user: @citizen, name: "sms").reload.granted?,
                 "the grant survives the with_lock transaction"
          assert Decidim::Bih::CitizenPhoneRecord.exists?(user: @citizen)
        end

        test "grant_sms_authorization delegates to Complete and writes the phone rows" do
          pending_authorization!
          caller_class = Class.new do
            include Decidim::Bih::GrantsSmsAuthorization
          end

          assert caller_class.new.grant_sms_authorization(@citizen, {}, expected_phone: PHONE)
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "grant_sms_authorization writes the phone rows for an already granted authorization" do
          granted_authorization!
          caller_class = Class.new do
            include Decidim::Bih::GrantsSmsAuthorization
          end

          assert caller_class.new.grant_sms_authorization(@citizen, nil, expected_phone: PHONE)
          assert_equal PHONE, Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "grant_sms_authorization raises for the durable caller when the grant cannot happen" do
          error = assert_raises(RuntimeError) do
            Class.new { include Decidim::Bih::GrantsSmsAuthorization }
                 .new.grant_sms_authorization(@citizen, nil, expected_phone: PHONE, raise_on_failure: true)
          end

          assert_match(/no_authorization/, error.message)
        end
      end
    end
  end
end
