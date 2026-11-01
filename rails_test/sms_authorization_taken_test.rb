# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Decidim::Bih::SmsAuthorization.taken? backs the one-step /registracija
      # form's phone-uniqueness check: a phone that already has a GRANTED sms
      # authorization in this organization must block a new registration
      # attempt with that number. A PENDING (never verified) authorization
      # must NOT block a new attempt -- an abandoned verification should not
      # permanently squat a phone number -- and authorizations belonging to a
      # different organization or a different phone number must never match.
      #
      # The stored number is whatever the citizen TYPED at verification time
      # (Decidim's MobilePhoneForm only strips non-[+0-9] before hashing), so
      # the lookup has to try every shape the number could have been saved
      # under -- see #phone_candidates.
      class SmsAuthorizationTakenTest < ActiveSupport::TestCase
        PHONE = "+38765123456"
        OTHER_PHONE = "+38765999999"

        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        def create_sms_authorization!(user:, granted:, phone: PHONE)
          Decidim::Authorization.create!(
            user:,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            granted_at: granted ? Time.current : nil
          )
        end

        test "a granted sms authorization for the phone in this organization is taken" do
          create_sms_authorization!(user: @citizen, granted: true)

          assert Decidim::Bih::SmsAuthorization.taken?(PHONE, organization: @organization)
        end

        test "a pending (never granted) authorization for the phone is not taken" do
          create_sms_authorization!(user: @citizen, granted: false)

          refute Decidim::Bih::SmsAuthorization.taken?(PHONE, organization: @organization)
        end

        test "a granted authorization for the phone in a different organization is not taken" do
          other_organization = create_organization
          other_citizen = FactoryBot.create(:user, :confirmed, organization: other_organization)
          create_sms_authorization!(user: other_citizen, granted: true)

          refute Decidim::Bih::SmsAuthorization.taken?(PHONE, organization: @organization)
        end

        test "a granted authorization for a different phone number is not taken" do
          create_sms_authorization!(user: @citizen, granted: true)

          refute Decidim::Bih::SmsAuthorization.taken?(OTHER_PHONE, organization: @organization)
        end

        test "a granted authorization is found whatever shape the citizen types" do
          create_sms_authorization!(user: @citizen, granted: true, phone: "065123456")

          ["065123456", "065 123 456", "+38765123456", "387 65 123 456"].each do |typed|
            assert Decidim::Bih::SmsAuthorization.taken?(typed, organization: @organization), typed
          end
        end

        test "the candidate shapes are the bounded set the verification flow can store" do
          assert_equal ["+38765123456", "38765123456", "065123456"],
                       Decidim::Bih::SmsAuthorization.phone_candidates("+387 65 123 456")
          assert_equal ["065123456", "+38765123456", "38765123456"],
                       Decidim::Bih::SmsAuthorization.phone_candidates("065 123 456")
          assert_equal 3, Decidim::Bih::SmsAuthorization.unique_id_candidates(PHONE).size
        end

        test "a blank number has no candidates and is never taken" do
          assert_empty Decidim::Bih::SmsAuthorization.phone_candidates("   ")
          assert_empty Decidim::Bih::SmsAuthorization.unique_id_candidates(nil)
          refute Decidim::Bih::SmsAuthorization.taken?("", organization: @organization)
        end
      end
    end
  end
end
