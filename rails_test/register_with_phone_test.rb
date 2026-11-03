# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Spec 5.3: one POST to /registracija opens the account. The citizen is
      # NOT signed in here — the account exists, the komšiluk is recorded, the
      # phone step is running and the browser holds a pending token. Points
      # arrive later, when the phone is actually proven.
      class RegisterWithPhoneTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper
        # This harness's ActiveSupport::TestCase does not pick up
        # ActionMailer::TestHelper on its own, and assert_emails is the whole
        # point of the reminder tests.
        include ActionMailer::TestHelper
        include ActiveSupport::Testing::TimeHelpers

        PHONE = "+38765123456"
        EMAIL = "mila@example.org"

        # Stands in for Decidim.sms_gateway_service so a test can see the
        # context Decidim's MobilePhoneForm handed the gateway. The engine's
        # own InfobipGateway needs both `user` and `organization` in there to
        # mint the one-tap verify link (R-D1) — a boolean return says nothing
        # about whether they arrived.
        class RecordingGateway
          class << self
            attr_accessor :contexts
          end
          self.contexts = []

          def initialize(_phone, _code, context = {})
            self.class.contexts << (context || {})
          end

          def deliver_code = true
        end

        # The provider that says no. MobilePhoneForm reads a falsy deliver_code
        # as a missing verification_code, so the handler is invalid and
        # PerformAuthorizationStep broadcasts :invalid.
        class RefusingGateway
          def initialize(_phone, _code, _context = {}); end

          def deliver_code = false
        end

        # The provider that falls over mid-send. Nothing catches this upstream,
        # so it escapes MobilePhoneForm's validation and the command has to
        # keep the already-committed account on its feet by itself.
        class RaisingGateway
          def initialize(_phone, _code, _context = {}); end

          def deliver_code = raise(IOError, "provider unreachable")
        end

        setup do
          @organization = create_organization
          @komsiluk = build_komsiluk!(@organization)
          # Without this, EmailConfirmation grandfathers every confirmed_at and
          # the "the e-mail is still unproven" assertions below pass vacuously.
          Decidim::Bih.phone_first_registration = true
        end

        teardown { Decidim::Bih.phone_first_registration = false }

        def form(**overrides)
          Decidim::Bih::PhoneRegistrationForm.from_params(
            {
              name: "Mila Gradjanka",
              email: EMAIL,
              mobile_phone_number: PHONE,
              komsiluk_id: @komsiluk.id,
              tos_agreement: "1",
              newsletter: "1",
              current_locale: "sr"
            }.merge(overrides)
          ).with_context(current_organization: @organization)
        end

        def register!(subject = form)
          outcome = { state: nil }
          Decidim::Bih::RegisterWithPhone.call(subject) do
            on(:ok) { |user, token| outcome = { state: :ok, user:, token: } }
            on(:invalid) { outcome = { state: :invalid } }
            on(:delivery_failed) { |user, token| outcome = { state: :delivery_failed, user:, token: } }
          end
          outcome
        end

        def with_gateway(klass)
          previous = Decidim.sms_gateway_service
          Decidim.sms_gateway_service = klass.name
          yield
        ensure
          Decidim.sms_gateway_service = previous
        end

        def sms_authorization_for(user) = Decidim::Authorization.find_by(user:, name: "sms")

        # The real grant, not `update!(granted_at:)`: a granted authorization
        # must have no verification_metadata (Decidim validates that), so a
        # bare column write on a pending row is invalid.
        def grant_phone!(user)
          perform_enqueued_jobs(only: Decidim::Bih::Goodwill::GoodwillAwardJob) do
            sms_authorization_for(user).grant!
          end
        end

        # A pending `sms` row for +phone+ owned by somebody else entirely.
        def stranger_verifying!(phone)
          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: stranger, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            verification_metadata: { "verification_code" => "123456", "code_sent_at" => Time.current },
            granted_at: nil
          )
          stranger
        end

        # A GRANTED `sms` row for +phone+ owned by somebody else: a proven
        # number, which the form refuses before the command is ever reached.
        def stranger_verified!(phone)
          stranger = FactoryBot.create(:user, :confirmed, organization: @organization)
          Decidim::Authorization.create!(
            user: stranger, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            granted_at: Time.current
          )
        end

        def process = @process ||= FactoryBot.create(:participatory_process, organization: @organization)

        def invite!(email: EMAIL, name: "Mila Pozvana", **attributes)
          user = Decidim::User.new(
            name:, email:,
            nickname: Decidim::UserBaseEntity.nicknamize(name, @organization.id),
            organization: @organization, **attributes
          )
          user.skip_invitation = true
          user.invite!
          user
        end

        # ------------------------------------------------------------ the account

        test "creates a confirmed, password-less, komsiluk-assigned pending citizen and sends the link" do
          outcome = nil
          assert_enqueued_with(job: Decidim::Bih::ResumeRegistrationEmailJob) do
            outcome = register!
          end

          assert_equal :ok, outcome[:state]
          user = outcome[:user]
          assert outcome[:token].present?

          assert user.confirmed?, "the account is active without an e-mail round trip"
          refute Decidim::Bih::EmailConfirmation.confirmed?(user), "the address is not proven by registering"
          assert_equal "sr", user.locale
          assert_equal EMAIL, user.email
          assert user.newsletter_notifications_at.present?
          # to_s on both sides: a harness organization may have no terms page at
          # all, and assert_equal(nil, nil) is deprecated in Minitest.
          assert_equal @organization.tos_version.to_s, user.accepted_tos_version.to_s,
                       "the citizen accepted the terms that are current now"
          assert user.encrypted_password.present?, "a random password stands in for the one nobody typed"
          assert user.password_updated_at.present?

          profile = Decidim::Bih::CitizenProfile.for_user(user, organization: @organization)
          assert profile.assigned?
          assert_equal @komsiluk.id, profile.komsiluk_id
          assert_equal "registration", profile.source

          authorization = sms_authorization_for(user)
          assert authorization.present?
          refute authorization.granted?, "the phone is not proven until the citizen answers"
          assert_equal Decidim::Bih::SmsAuthorization.unique_id_for(PHONE), authorization.unique_id

          assert_equal 1, Decidim::Bih::LoginToken.where(user:, purpose: "verify", consumed_at: nil).count
          assert_equal 0, goodwill_balance_for(user), "no points before the phone is proven"
        end

        test "the token it returns is the session variant, the one that may hand the session over" do
          outcome = register!

          access = Decidim::Bih::Registration::PendingAccess.resolve(outcome[:token], organization: @organization)
          assert_equal outcome[:user], access[:user]
          assert access[:handoff], "the registering browser's own token carries the hand-off right"
        end

        test "proving the phone pays the twenty registration points" do
          user = register![:user]
          assert_equal 0, goodwill_balance_for(user)

          grant_phone!(user)

          assert_equal 20, goodwill_balance_for(user),
                       "verification welcome plus the komšiluk chosen at registration"
        end

        test "the phone step hands the gateway the user and the organization" do
          with_gateway(RecordingGateway) do
            RecordingGateway.contexts = []
            user = register![:user]

            context = RecordingGateway.contexts.last
            assert_equal user, context[:user], "no user in the context means no one-tap link"
            assert_equal @organization, context[:organization]
          end
        end

        test "an invalid form creates nothing" do
          assert_no_difference(["Decidim::User.count", "Decidim::Authorization.count"]) do
            assert_equal :invalid, register!(form(komsiluk_id: nil))[:state]
          end
        end

        # A refused message must still leave something to come back to: without
        # a pending authorization row the returned token resolves to nothing
        # and the "message not sent, try again" page cannot even open.
        test "a refused delivery still leaves a pending account the citizen can resend from" do
          outcome = with_gateway(RefusingGateway) { register! }

          assert_equal :delivery_failed, outcome[:state]
          user = outcome[:user]
          authorization = sms_authorization_for(user)
          assert authorization.present?
          refute authorization.granted?
          assert Decidim::Bih::Registration::PendingAccess.resolve(outcome[:token], organization: @organization),
                 "the pending page opens so the citizen can ask for another message"
        end

        # A provider that falls over is the sharpest test of "commit first, send
        # second": if the account and the pending row were written inside the
        # same unit of work as the send, this exception would roll both away.
        test "a provider that falls over mid-send still leaves the account and its pending row" do
          outcome = nil
          assert_difference("Decidim::User.count", 1) do
            outcome = with_gateway(RaisingGateway) { register! }
          end

          assert_equal :delivery_failed, outcome[:state]
          user = outcome[:user]
          assert Decidim::User.exists?(user.id), "the account survived the provider"
          authorization = sms_authorization_for(user)
          assert authorization.present?, "so did the pending row the resend needs"
          refute authorization.granted?
          assert Decidim::Bih::CitizenProfile.for_user(user, organization: @organization).assigned?
          assert Decidim::Bih::Registration::PendingAccess.resolve(outcome[:token], organization: @organization)
          assert_empty Decidim::Bih::LoginToken.where(user:), "no verify token was minted by a failed send"
        end

        # ------------------------------------------------------------ the number

        test "a number somebody else is already verifying is refused before anything is created or sent" do
          stranger_verifying!(PHONE)
          subject = form

          with_gateway(RecordingGateway) do
            RecordingGateway.contexts = []
            assert_no_difference(["Decidim::User.count", "Decidim::Authorization.count"]) do
              assert_equal :invalid, register!(subject)[:state]
            end
            assert_empty RecordingGateway.contexts, "no message goes out for a number under verification"
          end

          assert_includes subject.errors.attribute_names, :mobile_phone_number
          # No locale pinned on either side: the command renders in the ambient
          # locale, which is the citizen's own once a request has set it.
          assert_equal [I18n.t("decidim.bih.registrations.errors.phone_pending")],
                       subject.errors[:mobile_phone_number]
        end

        # The other half of the rule: a claim nobody ever proved and nobody has
        # touched since the code died is not "in verification", it is litter —
        # and the number has to be taken off it, not merely ignored, or
        # Decidim's own duplicate check strands the newcomer at the SMS step.
        # The ROW stays: it is the stranger's only `sms` authorization, and
        # destroying it would take their whole pending registration with it.
        test "an abandoned claim on the number is released and the newcomer gets through" do
          stranger = stranger_verifying!(PHONE)
          abandoned = Decidim::Authorization.find_by(user: stranger, name: "sms")

          outcome = nil
          travel(Decidim::Bih::LoginToken::VERIFY_TTL + 1.minute) do
            outcome = register!
          end

          assert_equal :ok, outcome[:state]
          assert Decidim::Authorization.exists?(abandoned.id), "the stranger keeps their row"
          assert_nil abandoned.reload.unique_id, "but it no longer holds the number"
          assert sms_authorization_for(outcome[:user]).present?, "and the newcomer holds it instead"
        end

        # A proven number is a different thing entirely: the form refuses it,
        # the command is never reached, and nothing destroys the proof.
        test "a number already proven on another account is refused, and that proof is untouched" do
          stranger_verified!(PHONE)
          subject = form

          refute subject.valid?, "the form refuses a verified number"
          assert_includes subject.errors.attribute_names, :mobile_phone_number

          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register!(subject)[:state]
          end
          assert_equal 1, Decidim::Authorization.where(name: "sms").count,
                       "a granted claim is never cleared"
        end

        # The stored row is keyed on the number AS TYPED, so a citizen who
        # types the local form of a number somebody is verifying in E.164 has
        # to hit the same refusal.
        test "the pending-number check matches whichever shape the row was stored under" do
          stranger_verifying!("065123456")

          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register![:state]
          end
        end

        # ------------------------------------------------------------ invitations

        test "an unaccepted invitation to the same address is adopted, not duplicated" do
          invited = invite!
          assert invited.invitation_token.present?
          assert_nil invited.invitation_accepted_at

          outcome = nil
          assert_no_difference("Decidim::User.count") do
            outcome = register!
          end

          assert_equal :ok, outcome[:state]
          assert_equal invited.id, outcome[:user].id

          invited.reload
          assert invited.invitation_accepted_at.present?, "the invitation is accepted by registering"
          assert_nil invited.invitation_token
          assert_equal "Mila Gradjanka", invited.name, "the name the citizen typed wins"
          assert invited.confirmed?
          # to_s: the column keeps microseconds where the in-memory
          # organization value carries nanoseconds.
          assert_equal @organization.tos_version.to_s, invited.accepted_tos_version.to_s
          assert Decidim::Bih::CitizenProfile.for_user(invited, organization: @organization).assigned?
          assert sms_authorization_for(invited).present?
        end

        test "adopting an invitation preserves the explicit all-topic registration opt-out" do
          invited = invite!
          outcome = register!(form(newsletter: "0"))
          assert_equal :ok, outcome[:state]
          assert_equal invited.id, outcome[:user].id
          Decidim::Bih::TopicPreferences::TOPICS.each do |topic|
            refute Decidim::Bih::TopicPreferences.enabled?(invited.reload, topic:), topic
          end
          assert_nil invited.newsletter_notifications_at
        end

        test "an invited administrator is never adopted by a stranger who knows the address" do
          invited = invite!(admin: true)
          subject = form

          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register!(subject)[:state]
          end
          assert_includes subject.errors.attribute_names, :email, "the citizen is told which field is the problem"
          assert_nil invited.reload.invitation_accepted_at, "the admin invitation is untouched"
        end

        # Decidim invites a space administrator with `admin: false` and a role
        # row, so `admin?` says nothing about them. Adopting one of those would
        # hand a stranger a process administrator's account.
        test "an invited process administrator is never adopted" do
          invited = invite!
          Decidim::ParticipatoryProcessUserRole.create!(
            user: invited, participatory_process: process, role: "admin"
          )
          refute Decidim::Bih::RegisterWithPhone.adoptable?(invited)

          subject = form
          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register!(subject)[:state]
          end
          assert_includes subject.errors.attribute_names, :email
          assert_nil invited.reload.invitation_accepted_at
        end

        test "an invited private-space member is never adopted" do
          invited = invite!
          Decidim::ParticipatorySpace::Member.create!(user: invited, participatory_space: process)
          refute Decidim::Bih::RegisterWithPhone.adoptable?(invited)

          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register![:state]
          end
        end

        test "an invited officialized account is never adopted" do
          invited = invite!
          invited.update_column(:officialized_at, Time.current) # rubocop:disable Rails/SkipsModelValidations
          refute Decidim::Bih::RegisterWithPhone.adoptable?(invited.reload)

          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register![:state]
          end
        end

        # Refused by BOTH layers: the form's own uniqueness check never lets
        # this reach the command, and the command would refuse it too.
        test "an ordinary existing account is still refused" do
          existing = FactoryBot.create(:user, :confirmed, organization: @organization, email: EMAIL)
          subject = form

          refute subject.valid?, "the form refuses it first"
          refute Decidim::Bih::RegisterWithPhone.adoptable?(existing), "and the command would too"

          assert_no_difference("Decidim::User.count") do
            assert_equal :invalid, register!(subject)[:state]
          end
          assert_includes subject.errors.attribute_names, :email
        end

        # ------------------------------------------------------------ resume mail

        test "the resume e-mail is sent once, fifteen minutes later, and only while still pending" do
          user = register![:user]

          assert_enqueued_with(job: Decidim::Bih::ResumeRegistrationEmailJob, args: [user.id, @organization.id])

          assert_emails(1) { Decidim::Bih::ResumeRegistrationEmailJob.perform_now(user.id, @organization.id) }
          assert_emails(0) { Decidim::Bih::ResumeRegistrationEmailJob.perform_now(user.id, @organization.id) }

          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          assert_emails(0) { Decidim::Bih::ResumeRegistrationEmailJob.perform_now(other.id, @organization.id) }
        end

        test "a citizen who has already verified never gets the reminder" do
          user = register![:user]
          grant_phone!(user)

          assert_emails(0) { Decidim::Bih::ResumeRegistrationEmailJob.perform_now(user.id, @organization.id) }
        end

        test "the resume e-mail carries an e-mail token that can never hand the session over" do
          user = register![:user]
          Decidim::Bih::ResumeRegistrationEmailJob.perform_now(user.id, @organization.id)

          mail = ActionMailer::Base.deliveries.last
          assert_equal [user.email], mail.to
          assert_equal I18n.t("decidim.bih.registration_mailer.resume.subject", locale: :sr), mail.subject

          body = mail.text_part ? mail.text_part.decoded : mail.body.decoded
          match = body.match(%r{https://#{Regexp.escape(@organization.host)}\S*[?&]pending_token=([^\s&"'<>]+)})
          assert match, "the reminder carries a link back to the pending page: #{body}"

          access = Decidim::Bih::Registration::PendingAccess.resolve(
            CGI.unescape(match[1]), organization: @organization
          )
          assert_equal user, access[:user]
          refute access[:handoff], "a mailed token must never sign a browser in"

          refute Decidim::Bih::EmailConfirmation.confirmed?(user), "the reminder proves no address"
          refute sms_authorization_for(user).granted?, "the reminder verifies nothing"
        end
      end
    end
  end
end
