# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class CitizenPhoneTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "stores and reads back a verified phone number" do
          grant_phone!("+38765123456")
          Decidim::Bih::CitizenPhone.store!(@citizen, "+387 65 123 456")

          assert_equal "+38765123456", Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "storing twice keeps one row per citizen" do
          grant_phone!("+38765999888")
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765999888")

          assert_equal 1, Decidim::Bih::CitizenPhoneRecord.where(user: @citizen).count
          assert_equal "+38765999888", Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "returns nil for a citizen who never verified" do
          assert_nil Decidim::Bih::CitizenPhone.for(@citizen)
        end

        test "a storage failure logs only the exception class, never the number" do
          # The happy path never calls Rails.logger at all, so exercising it
          # would prove nothing about what a real failure logs. Force the
          # rescue branch instead by making the persisted record's save! raise.
          fake_record = Object.new
          def fake_record.organization=(_); end

          def fake_record.phone=(_); end

          def fake_record.verified_at=(_); end

          def fake_record.save!
            raise StandardError, "boom for 65123456"
          end

          log = StringIO.new
          original = Rails.logger
          Rails.logger = ActiveSupport::Logger.new(log)

          begin
            Decidim::Bih::CitizenPhoneRecord.stub(:find_or_initialize_by, fake_record) do
              Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
            end
          ensure
            Rails.logger = original
          end

          assert_includes log.string, "StandardError"
          refute_includes log.string, "65123456"
        end

        test "the retention contract covers the stored phone table" do
          bucket = Decidim::Bih::PrivacyAuditContracts::RETENTION_BUCKETS
                   .find { |b| b[:id] == "citizen_phones" }

          assert bucket, "novi PII mora imati retencioni bucket"
          assert_includes bucket[:storage], "decidim_bih_citizen_phones"
          assert_includes bucket[:excludes_from_run_history], "phone"
        end

        test "the retention sweep deletes a stored phone past the cutoff" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          Decidim::Bih::CitizenPhoneRecord.find_by(user: @citizen)
                                          .update_column(:verified_at, 400.days.ago) # rubocop:disable Rails/SkipsModelValidations

          result = Decidim::Bih::Privacy::RetentionSweep.call(
            organization: @organization,
            citizen_phone_before: 300.days.ago,
            dry_run: false
          )

          assert_equal 1, result.counts[:citizen_phones]
          assert_nil Decidim::Bih::CitizenPhoneRecord.find_by(user: @citizen)
        end

        test "the retention sweep dry run counts without deleting anything" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")
          Decidim::Bih::CitizenPhoneRecord.find_by(user: @citizen)
                                          .update_column(:verified_at, 400.days.ago) # rubocop:disable Rails/SkipsModelValidations

          result = Decidim::Bih::Privacy::RetentionSweep.call(
            organization: @organization,
            citizen_phone_before: 300.days.ago,
            dry_run: true
          )

          assert_equal 1, result.counts[:citizen_phones]
          assert Decidim::Bih::CitizenPhoneRecord.exists?(user: @citizen)
        end

        test "the retention sweep leaves phones newer than the cutoff alone" do
          Decidim::Bih::CitizenPhone.store!(@citizen, "+38765123456")

          result = Decidim::Bih::Privacy::RetentionSweep.call(
            organization: @organization,
            citizen_phone_before: 300.days.ago,
            dry_run: false
          )

          assert_equal 0, result.counts[:citizen_phones]
          assert Decidim::Bih::CitizenPhoneRecord.exists?(user: @citizen)
        end

        private

        def grant_phone!(phone)
          Decidim::Authorization.create!(user: @citizen, name: "sms",
                                         unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone), granted_at: Time.current)
        end
      end
    end
  end
end
