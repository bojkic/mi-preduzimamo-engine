# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Decidim::Bih::PhoneRegistrationForm is the one-step /registracija form:
      # name, an UNPROVEN e-mail, the phone that becomes the login, a komsiluk
      # and two consents. There is deliberately no password attribute.
      #
      # The form runs against the database (e-mail and phone uniqueness, the
      # nickname disambiguation and the komsiluk lookup), so it lives in the
      # Rails harness rather than in the host-free unit suite.
      class PhoneRegistrationFormTest < ActiveSupport::TestCase
        PHONE = "+38765123456"
        EMAIL = "mila@example.org"

        setup do
          @organization = create_organization
          @komsiluk = build_komsiluk!(@organization, name: "Ledinci")
        end

        def form(**over)
          Decidim::Bih::PhoneRegistrationForm.from_params(
            {
              name: "Mila Gradjanka",
              email: EMAIL,
              mobile_phone_number: "065 123 456",
              komsiluk_id: @komsiluk.id,
              tos_agreement: "1",
              newsletter: "0",
              current_locale: "sr"
            }.merge(over)
          ).with_context(current_organization: @organization)
        end

        def errors_on(**over)
          subject = form(**over)
          refute subject.valid?
          subject.errors.attribute_names
        end

        def grant_sms_authorization!(user, phone: PHONE)
          Decidim::Authorization.create!(
            user:,
            name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            granted_at: Time.current
          )
        end

        def invite!(user, accepted: false)
          user.update!(
            invitation_token: SecureRandom.hex(10),
            invitation_created_at: Time.current,
            invitation_sent_at: Time.current,
            invitation_accepted_at: accepted ? Time.current : nil
          )
          user
        end

        test "a complete form is valid and normalizes the phone to E.164" do
          subject = form

          assert subject.valid?, subject.errors.full_messages.inspect
          assert_equal PHONE, subject.normalized_phone
          assert_equal @komsiluk, subject.komsiluk
          assert_nil subject.newsletter_at
          assert subject.nickname.present?
        end

        test "there is no password attribute" do
          refute_includes Decidim::Bih::PhoneRegistrationForm.attribute_names, "password"
          refute form.respond_to?(:password)
        end

        test "the social prefill can read and write the phone attribute" do
          subject = form(mobile_phone_number: "")
          subject.mobile_phone_number = PHONE

          assert_equal PHONE, subject.mobile_phone_number
        end

        test "tos, komsiluk, phone, e-mail and name are required" do
          assert_includes errors_on(tos_agreement: "0"), :tos_agreement
          assert_includes errors_on(komsiluk_id: nil), :komsiluk_id
          assert_includes errors_on(mobile_phone_number: ""), :mobile_phone_number
          assert_includes errors_on(email: "nije-mejl"), :email
          assert_includes errors_on(name: " "), :name
        end

        test "a blank phone is reported once, as missing rather than as invalid" do
          subject = form(mobile_phone_number: "")
          refute subject.valid?

          assert_equal 1, subject.errors[:mobile_phone_number].size
        end

        test "a name with markup characters is rejected" do
          assert_includes errors_on(name: "Mila <script>"), :name
        end

        # ActiveModel resolves a symbol error type LAZILY, when the message is read
        # rather than when it is added, so the read has to happen inside the locale
        # block too.
        test "the declarative validation messages read in Latin ijekavian under sr" do
          messages = I18n.with_locale(:sr) do
            subject = form(name: " ")
            subject.valid?
            subject.errors[:name]
          end

          assert_equal ["ne može biti prazno"], messages
        end

        test "an implausible phone number is rejected with a localized message" do
          subject = form(mobile_phone_number: "12345")

          refute subject.valid?
          assert_equal [I18n.t("decidim.bih.registrations.errors.phone_invalid")], subject.errors[:mobile_phone_number]
        end

        test "an e-mail already used in the organization is rejected" do
          FactoryBot.create(:user, :confirmed, organization: @organization, email: EMAIL)
          subject = form

          refute subject.valid?
          assert subject.errors[:email].any?
        end

        test "the e-mail is stripped and downcased before it is compared" do
          FactoryBot.create(:user, :confirmed, organization: @organization, email: EMAIL)
          subject = form(email: "  Mila@Example.ORG ")

          assert_equal EMAIL, subject.email
          refute subject.valid?
          assert_equal [I18n.t("decidim.bih.registrations.errors.email_taken")], subject.errors[:email]
        end

        test "the same e-mail in another organization does not block registration" do
          FactoryBot.create(:user, :confirmed, organization: create_organization, email: EMAIL)

          assert form.valid?
        end

        # The launch invitations create Decidim::User rows up front. Until the
        # citizen opens the invitation mail that row is not their account yet,
        # and RegisterWithPhone adopts it -- so it must not turn them away.
        test "an e-mail holding an unaccepted invitation does not block registration" do
          invite!(FactoryBot.create(:user, organization: @organization, email: EMAIL))

          subject = form
          assert subject.valid?, subject.errors.full_messages.inspect
        end

        test "an e-mail whose invitation was accepted is rejected" do
          invite!(FactoryBot.create(:user, :confirmed, organization: @organization, email: EMAIL), accepted: true)

          assert_includes errors_on, :email
        end

        test "an e-mail on a managed account is rejected" do
          FactoryBot.create(:user, :managed, organization: @organization, email: EMAIL, nickname: "mila_managed")

          assert_includes errors_on, :email
        end

        test "a phone already bound to a granted sms authorization is rejected" do
          grant_sms_authorization!(FactoryBot.create(:user, :confirmed, organization: @organization))
          subject = I18n.with_locale(:en) { form.tap(&:valid?) }

          assert_equal(
            ["This number is already confirmed on another account. Sign in with your phone number instead of registering again."],
            subject.errors[:mobile_phone_number]
          )
        end

        # Delivery A stores the number as the citizen typed it, so the same
        # person can sit in the table under the local shape.
        test "a phone granted under the local shape is rejected when typed as E.164" do
          grant_sms_authorization!(FactoryBot.create(:user, :confirmed, organization: @organization), phone: "065123456")

          assert_includes errors_on(mobile_phone_number: "+387 65 123 456"), :mobile_phone_number
        end

        test "the same phone verified in another organization does not block registration" do
          grant_sms_authorization!(FactoryBot.create(:user, :confirmed, organization: create_organization))

          assert form.valid?
        end

        test "a komsiluk from another organization is rejected" do
          foreign = build_komsiluk!(create_organization)
          subject = form(komsiluk_id: foreign.id)

          refute subject.valid?
          assert_equal [I18n.t("decidim.bih.registrations.errors.komsiluk_invalid")], subject.errors[:komsiluk_id]
          assert_nil subject.komsiluk
        end

        test "an mz is not an acceptable komsiluk" do
          mz = Decidim::Bih::LocalArea.create!(
            decidim_organization_id: @organization.id,
            kind: "mz",
            slug: "mz-#{SecureRandom.hex(4)}",
            name: { "sr" => "Centar" }
          )

          assert_includes errors_on(komsiluk_id: mz.id), :komsiluk_id
        end

        test "komsiluk follows the current value of komsiluk_id" do
          other = build_komsiluk!(@organization, name: "Dvorovi")
          subject = form

          assert_equal @komsiluk, subject.komsiluk
          subject.komsiluk_id = other.id
          assert_equal other, subject.komsiluk
          subject.komsiluk_id = nil
          assert_nil subject.komsiluk
        end

        test "a checked newsletter box stamps a subscription time" do
          subject = form(newsletter: "1")

          assert subject.valid?, subject.errors.full_messages.inspect
          assert subject.newsletter_at.present?
        end

        test "komsiluk_options lists this organization's komsiluci by name" do
          build_komsiluk!(@organization, name: "Amajlije")
          build_komsiluk!(create_organization, name: "Aaa druga organizacija")

          names = form.komsiluk_options.map { |area| area.name["sr"] }

          assert_equal %w(Amajlije Ledinci), names
        end

        # parameterize transliterates Latin accents only, so without folding the
        # name to Latin first a Cyrillic name yields an EMPTY nickname -- which
        # then fails Decidim::User's own validation when the account is saved.
        test "a Cyrillic name still produces a usable, unique nickname" do
          first = form(name: "Мила Грађанка").nickname

          assert_equal "mila_gradanka", first
          assert_match Decidim::User::REGEXP_NICKNAME, first

          FactoryBot.create(:user, :confirmed, organization: @organization, nickname: first)
          refute_equal first, form(name: "Мила Грађанка").nickname
        end

        test "latin diacritics are folded into the nickname" do
          assert_equal "dorde_cvorovic", form(name: "Đorđe Čvorović").nickname
        end

        test "a name that parameterizes to nothing falls back to a generated nickname" do
          subject = form(name: "🎉")

          assert_match(/\Agradjanin_[0-9a-f]{6}\z/, subject.nickname)
          assert_equal subject.nickname, subject.nickname, "the generated nickname must be stable"
          refute_equal subject.nickname, form(name: "🎉").nickname
        end
      end
    end
  end
end
