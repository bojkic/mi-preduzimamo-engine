# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      class SimplifiedRegistrationTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers
        include ActiveJob::TestHelper
        include ActiveSupport::Testing::TimeHelpers

        class RedisCounter
          def initialize = @values = {}

          def get(key) = @values[key].to_s

          def eval(_script, keys:, **_options) = @values[keys.first] = @values.fetch(keys.first, 0) + 1

          def del(key) = @values.delete(key)
        end

        class Gateway
          class << self
            attr_accessor :calls
          end
          def initialize(phone, code, context = {})
            self.class.calls << { phone:, code:, context: }
          end

          def deliver_code
            last = self.class.calls.last
            LoginToken.issue!(user: last[:context][:user], purpose: "verify", phone: last[:phone])
            true
          end
        end

        class RecipientMailer < ActionMailer::Base # rubocop:disable Rails/ApplicationMailer -- Exercise the shared mailer boundary without application layout state.
          def sample(recipients)
            mail(from: "platform@example.org", to: recipients, subject: I18n.t("decidim.user_update_mailer.subject"), body: I18n.t("decidim.user_update_mailer.subject"))
          end
        end

        setup do
          @organization = create_organization
          host! @organization.host
          @komsiluk = build_komsiluk!(@organization)
          @settings = [Decidim::Bih.phone_first_registration, Decidim::Bih.simplified_registration, Decidim::Bih.registration_newsletter_default]
          @gateway = Decidim.sms_gateway_service
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih.simplified_registration = true
          Decidim::Bih.registration_newsletter_default = true
          Decidim.sms_gateway_service = Gateway.name
          Gateway.calls = []
          Decidim::Bih::RegistrationsController.attempt_limiter_redis = RedisCounter.new
          travel_to Time.utc(2026, 10, 7, 12)
        end

        teardown do
          Decidim::Bih.phone_first_registration, Decidim::Bih.simplified_registration, Decidim::Bih.registration_newsletter_default = @settings
          Decidim.sms_gateway_service = @gateway
          Decidim::Bih::RegistrationsController.attempt_limiter_redis = nil
          travel_back
        end

        def base = Decidim::Bih.registration_path_for

        def pending = "#{base}/potvrda"

        def signup(phone: "+38765123456", **extra)
          post base, params: { user: { name: "Nova Gradjanka", mobile_phone_number: phone, tos_agreement: "1", **extra } }
          Decidim::User.where(organization: @organization).order(:id).last
        end

        def authorization(user) = Decidim::Authorization.find_by!(user:, name: "sms")

        def confirm(user)
          post "#{pending}/kod", params: { verification_code: authorization(user).verification_metadata["verification_code"] }
        end

        test "two different numbers create distinct empty-email citizens without geography or email jobs" do
          first = signup(email: "forged@example.org", komsiluk_id: @komsiluk.id, newsletter: "1")
          assert_redirected_to pending
          second = signup(phone: "+38765111222")
          assert_redirected_to pending
          assert_not_equal first.id, second.id
          [first, second].each do |user|
            assert_equal "", user.email
            assert user.phone_only_registration?
            assert user.confirmed?
            assert_not CitizenProfile.exists?(decidim_user_id: user.id)
            assert_nil user.newsletter_notifications_at
            TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
            assert_not authorization(user).granted?
          end
          assert_no_enqueued_jobs(only: ResumeRegistrationEmailJob)
        end

        test "blank-email exceptions do not weaken Devise real-email nickname or administrator validation" do
          user = signup
          other = signup(phone: "+38765111222")
          user.update_columns(email: "real@example.org") # rubocop:disable Rails/SkipsModelValidations -- Set confirmed-email fixtures or deliberately exercise the database constraint.
          other.email = user.email
          assert_not other.valid?
          assert_includes other.errors[:email], I18n.t("errors.messages.taken")
          other.email = ""
          other.nickname = user.nickname
          assert_not other.valid?
          assert other.errors[:nickname].present?
          other.nickname = "different_citizen"
          other.admin = true
          assert_not other.valid?
          assert other.errors[:email].present?
          other.admin = false
          other.extended_data = {}
          assert_not other.valid?
          assert other.errors[:email].present?
        end

        test "partial database index permits blank emails but refuses duplicate real email bypassing validation" do
          first = signup
          second = signup(phone: "+38765111222")
          first.update_columns(email: "same@example.org") # rubocop:disable Rails/SkipsModelValidations -- Set confirmed-email fixtures or deliberately exercise the database constraint.
          assert_raises ActiveRecord::RecordNotUnique do
            Decidim::User.transaction(requires_new: true) { second.update_columns(email: first.email) } # rubocop:disable Rails/SkipsModelValidations -- Set confirmed-email fixtures or deliberately exercise the database constraint.
          end
          assert_equal "", second.reload.email
        end

        test "phone-only AccountForm can save name and profile with blank email and sends no update mail" do
          user = signup
          form = Decidim::AccountForm.from_params(name: "Novo Ime", nickname: user.nickname, email: "", about: "Moj profil", locale: "sr")
                                     .with_context(current_user: user, current_organization: @organization)
          assert form.valid?, form.errors.full_messages.join(", ")
          saved = false
          assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
            Decidim::UpdateAccount.call(form) { on(:ok) { saved = true } }
          end
          assert saved
          assert_equal "Novo Ime", user.reload.name
          assert_equal "Moj profil", user.about
          ordinary = FactoryBot.create(:user, :confirmed, organization: @organization)
          form = Decidim::AccountForm.from_params(name: ordinary.name, nickname: ordinary.nickname, email: "", locale: "sr")
                                     .with_context(current_user: ordinary, current_organization: @organization)
          assert_not form.valid?
          assert form.errors[:email].present?
        end

        test "verification requires komsiluk then a valid assignment goes to member home" do
          user = signup
          confirm(user)
          assert authorization(user).reload.granted?
          assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1"
          get Decidim::Bih.public_path("komsiluk")
          assert_response :success
          assert_select "#bih-komsiluk-select[required]"
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: "", source: "dropdown" }
          assert_not CitizenProfile.find_by(decidim_user_id: user.id)&.assigned?
          foreign = build_komsiluk!(create_organization)
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: foreign.id, source: "dropdown" }
          assert_not CitizenProfile.find_by(decidim_user_id: user.id)&.assigned?
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          assert_redirected_to Decidim::Bih.public_path("moj-nalog")
          assert CitizenProfile.find_by!(decidim_user_id: user.id).assigned?
        end

        test "phone verified without komsiluk qualifies only on assignment and cutoff is exclusive" do
          user = signup
          confirm(user)
          grant = authorization(user).reload.granted_at
          assert_empty(Race::SnapshotBuilder.new(organization: @organization).call.fetch("items").select { |item| item["kind"] == "registered" && item["eligible"] })
          travel 2.minutes
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          profile = CitizenProfile.find_by!(decidim_user_id: user.id)
          edition = Race::Edition.ensure_for!(@organization)
          member = Race::Membership.capture!(edition, profile)
          assert_equal [grant, profile.assigned_at].max, member.qualified_at
          assert_operator member.qualified_at, :>, grant
          config = Race::Config.new(organization: @organization)
          travel_to config.window_to - 2.minutes
          sign_out user
          late = signup(phone: "+38765111222")
          confirm(late)
          travel_to config.window_to
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          items = Race::SnapshotBuilder.new(organization: @organization).call.fetch("items")
          assert_not(items.any? { |item| item["kind"] == "registered" && item["user_id"] == late.id && item["eligible"] })
        end

        test "the komsiluk notification default is checked but absent and explicit unchecked requests stay off" do
          user = signup
          confirm(user)
          get Decidim::Bih.public_path("komsiluk")
          assert_select "#mi-komsiluk-notifications[checked]"
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "0" }
          TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user.reload, topic:) }
          assert_nil user.newsletter_notifications_at
          sign_out user
          second = signup(phone: "+38765111222")
          confirm(second)
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "1" }
          TopicPreferences::TOPICS.each { |topic| assert TopicPreferences.enabled?(second.reload, topic:) }
          assert second.newsletter_notifications_at
          TopicPreferences.set_all!(second, enabled: false)
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "1" }
          TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(second.reload, topic:) }
        end

        test "first real email can be added using the verified phone session and remains unconfirmed until its link" do
          user = signup
          confirm(user)
          form = Decidim::AccountForm.from_params(name: user.name, nickname: user.nickname, email: "new@example.org", locale: "sr")
                                     .with_context(current_user: user, current_organization: @organization)
          assert form.valid?, form.errors.full_messages.join(", ")
          saved = false
          Decidim::UpdateAccount.call(form) { on(:ok) { saved = true } }
          assert saved
          assert_equal "", user.reload.email
          assert_equal "new@example.org", user.unconfirmed_email
          assert_not EmailConfirmation.confirmed?(user)
        end

        test "unverified phone-only accounts cannot use the first-email exception" do
          user = signup
          form = Decidim::AccountForm.from_params(name: user.name, nickname: user.nickname, email: "new@example.org", locale: "sr")
                                     .with_context(current_user: user, current_organization: @organization)
          assert_not form.valid?
          assert form.errors[:old_password].present?
        end

        test "existing members changing komsiluk keep preferences and locked race membership" do
          Race::Edition.ensure_for!(@organization).update!(baseline_at: Time.current)
          user = signup
          confirm(user)
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "1" }
          profile = CitizenProfile.find_by!(decidim_user_id: user.id)
          member = Race::Membership.capture!(Race::Edition.ensure_for!(@organization), profile)
          qualified_at = member.qualified_at
          TopicPreferences.set_all!(user, enabled: false)
          other_area = build_komsiluk!(@organization)
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: other_area.id, source: "dropdown", komsiluk_notifications: "1" }
          assert_redirected_to Decidim::Bih.public_path("komsiluk")
          assert_equal @komsiluk.id, member.reload.komsiluk_id
          assert_equal qualified_at, member.qualified_at
          TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user.reload, topic:) }
        end

        test "existing email citizens assigning their first komsiluk in settings retain their destination and preferences" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          TopicPreferences.set_all!(user, enabled: false)
          Decidim::Authorization.create!(user:, name: "sms", granted_at: Time.current)
          sign_in user
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "1" }
          assert_redirected_to Decidim::Bih.public_path("komsiluk")
          assert CitizenProfile.find_by!(decidim_user_id: user.id).assigned?
          TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user.reload, topic:) }
          assert_nil user.newsletter_notifications_at
        end

        test "existing email citizens completing phone authentication choose komsiluk then return home" do
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          TopicPreferences.set_all!(user, enabled: false)
          phone = "+38765123456"
          Decidim::Authorization.create!(user:, name: "sms", unique_id: SmsAuthorization.unique_id_for(phone), granted_at: Time.current)
          raw = LoginToken.issue!(user:, purpose: "verify", phone:)
          post Decidim::Bih.magic_link_path(raw)
          assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1"
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "1" }
          assert_redirected_to Decidim::Bih.public_path("moj-nalog")
          TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user.reload, topic:) }
          assert_nil user.newsletter_notifications_at
        end

        test "duplicate one-tap proof cannot grant twice or duplicate verification and komsiluk awards" do
          user = signup
          raw = LoginToken.issue!(user:, purpose: "verify", phone: "+38765123456")
          perform_enqueued_jobs(only: Goodwill::GoodwillAwardJob) do
            post Decidim::Bih.magic_link_path(raw)
            patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown", komsiluk_notifications: "1" }
          end
          balance = goodwill_balance_for(user)
          assert_equal 20, balance
          granted = authorization(user).reload.granted_at
          perform_enqueued_jobs(only: Goodwill::GoodwillAwardJob) do
            post Decidim::Bih.magic_link_path(raw)
            patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          end
          assert_equal balance, goodwill_balance_for(user)
          assert_equal granted, authorization(user).reload.granted_at
        end

        test "registration analytics expose only daily totals and age buckets with tenant isolation" do
          user = signup
          confirm(user)
          data = Admin::RegistrationFunnel.new(organization: @organization).call
          assert_equal 30, data.fetch("daily").size
          assert_equal({ "day" => "2026-10-07", "created" => 1, "verified" => 1, "komsiluk" => 0 }, data.fetch("daily").last)
          assert_equal 1, data.fetch("waiting").fetch("under_hour")
          serialized = JSON.generate(data)
          assert_not serialized.include?(user.name)
          assert_not serialized.include?(user.nickname)
          assert_not serialized.include?("+387")
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          data = Admin::RegistrationFunnel.new(organization: @organization).call
          assert_equal 1, data.fetch("daily").last.fetch("komsiluk")
          assert_equal 0, data.fetch("waiting").values.sum
          assert_equal(0, Admin::RegistrationFunnel.new(organization: create_organization).call.fetch("daily").sum { |row| row.fetch("created") })
        end

        test "daily completed komsiluk counts use the later step and Sarajevo midnight" do
          travel_to Time.utc(2026, 10, 6, 21, 30)
          user = FactoryBot.create(:user, :confirmed, organization: @organization)
          profile = CitizenProfile.for_user(user, organization: @organization)
          profile.assign_komsiluk!(@komsiluk, source: "dropdown")
          travel_to Time.utc(2026, 10, 6, 22, 15)
          Decidim::Authorization.create!(user:, name: "sms", granted_at: Time.current)
          rows = Admin::RegistrationFunnel.new(organization: @organization).call.fetch("daily").index_by { |row| row.fetch("day") }
          assert_equal({ "day" => "2026-10-06", "created" => 1, "verified" => 0, "komsiluk" => 0 }, rows.fetch("2026-10-06"))
          assert_equal({ "day" => "2026-10-07", "created" => 0, "verified" => 1, "komsiluk" => 1 }, rows.fetch("2026-10-07"))
        end

        test "saved board destination cannot bypass required komsiluk and survives renewed session" do
          destination = Decidim::Bih.public_path("komsiluk-board")
          get destination
          assert_response :redirect
          user = signup
          confirm(user)
          assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1"
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          assert_redirected_to destination
          get destination
          assert_response :success
        end

        test "saved citizen destination also survives registration and waits for komsiluk" do
          destination = Decidim::Bih.public_path("moj-nalog/poruke")
          get destination
          user = signup
          confirm(user)
          assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1"
          patch Decidim::Bih.public_path("komsiluk"), params: { komsiluk_id: @komsiluk.id, source: "dropdown" }
          assert_redirected_to destination
        end

        test "one-tap verification works in another browser and original polling also requires komsiluk" do
          user = signup
          raw = LoginToken.issue!(user:, purpose: "verify", phone: "+38765123456")
          phone_browser = open_session
          phone_browser.host! @organization.host
          phone_browser.post Decidim::Bih.magic_link_path(raw)
          phone_browser.assert_redirected_to "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1"
          post "#{pending}/status"
          assert_response :success
          assert_equal "verified", response.parsed_body["state"]
          assert_equal "#{Decidim::Bih.public_path("komsiluk")}?setup=1&app=1", response.parsed_body["next"]
        end

        test "onboarding destination rejects external expired and other-user entries" do
          user = signup
          other = signup(phone: "+38765111222")
          destination = Decidim::Bih.public_path("moj-nalog/poruke")
          session = {}
          Onboarding::ReturnPath.store(session, user:, organization: @organization, path: "//evil.example")
          assert_empty session
          Onboarding::ReturnPath.store(session, user:, organization: @organization, path: destination)
          assert_nil Onboarding::ReturnPath.consume(session, user: other, organization: @organization)
          Onboarding::ReturnPath.store(session, user:, organization: @organization, path: destination)
          travel 2.hours + 1.second
          assert_nil Onboarding::ReturnPath.consume(session, user:, organization: @organization)
          Onboarding::ReturnPath.store(session, user:, organization: @organization, path: destination)
          assert_nil Onboarding::ReturnPath.consume(session, user:, organization: create_organization)
          report = Decidim::Bih.public_path("prijave/new")
          Onboarding::ReturnPath.store(session, user:, organization: @organization, path: report)
          assert_equal report, Onboarding::ReturnPath.consume(session, user:, organization: @organization)
        end

        test "queued core account mail to an absent email cannot be delivered while real-email mail remains intact" do
          user = signup
          deliveries = ActionMailer::Base.deliveries.size
          assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
            mail = Decidim::UserUpdateMailer.notify(user, ["name"])
            assert_instance_of ActionMailer::Base::NullMail, mail
            mail.deliver_later
          end
          # Parameterized and previously queued actions must also remain safe
          # at the shared recipient boundary.
          ActionMailer::MailDeliveryJob.perform_now("Decidim::UserUpdateMailer", "notify", "deliver_now", params: {}, args: [user, ["name"]])
          assert_equal deliveries, ActionMailer::Base.deliveries.size
          user.update_columns(email: "real@example.org") # rubocop:disable Rails/SkipsModelValidations -- Set confirmed-email fixtures or deliberately exercise the database constraint.
          mail = Decidim::UserUpdateMailer.notify(user, ["name"])
          assert mail.message.perform_deliveries
          assert_equal [user.email], mail.message.to
        end

        test "blank confirmation and invitation requests never adopt a phone-only account" do
          first = signup
          second = signup(phone: "+38765111222")
          old_tokens = [first, second].map(&:confirmation_token)
          assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
            result = Decidim::User.send_confirmation_instructions(email: "", organization: @organization)
            assert result.new_record?
            assert result.errors[:email].present?
            invitation = Decidim::User.invite!(email: "", organization: @organization, name: "Invited", nickname: "invited")
            assert invitation.new_record?
            assert invitation.errors[:email].present?
          end
          assert_equal old_tokens, [first.reload, second.reload].map(&:confirmation_token)
          assert_nil first.invitation_token
          assert_nil second.invitation_token
        end

        test "mixed mail recipients retain deliverable addresses and discard missing ones" do
          mail = RecipientMailer.sample(["", "valid@example.org", nil, " "]).message
          assert_equal ["valid@example.org"], mail.to
          assert mail.perform_deliveries
          assert_instance_of ActionMailer::Base::NullMail, RecipientMailer.sample(["", nil]).message
        end

        test "whitespace-only email is normalized only for marked phone-only citizens" do
          first = signup
          second = signup(phone: "+38765111222")
          [first, second].each do |user|
            user.update!(email: " ")
            assert_equal "", user.reload.email
          end
        end

        test "blank password recovery never selects a phone-only account or sends a reset" do
          first = signup
          second = signup(phone: "+38765111222")
          assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
            post "/sr/users/password", params: { user: { email: "" } }
          end
          assert_nil first.reload.reset_password_token
          assert_nil second.reload.reset_password_token
        end

        test "index migration can roll back before phone-only accounts exist" do
          require File.join(Decidim::Bih::Engine.root, "db/migrate/20261007130000_allow_phone_only_citizen_emails")
          migration = AllowPhoneOnlyCitizenEmails.new
          migration.migrate(:down)
          index = ActiveRecord::Base.connection.indexes(:decidim_users).find { |entry| entry.name == AllowPhoneOnlyCitizenEmails::INDEX }
          assert_no_match(/email.*<>/, index.where)
          migration.migrate(:up)
          second = signup(phone: "+38765111222")
          assert second.persisted?
          assert_equal "", second.email
        end

        test "an index replacement failure after dropping the old index rolls back and can be retried" do
          require File.join(Decidim::Bih::Engine.root, "db/migrate/20261007130000_allow_phone_only_citizen_emails")
          migration = AllowPhoneOnlyCitizenEmails.new
          connection = ActiveRecord::Base.connection
          before = connection.indexes(:decidim_users).find { |entry| entry.name == AllowPhoneOnlyCitizenEmails::INDEX }
          assert_raises RuntimeError do
            Decidim::User.transaction(requires_new: true) do
              connection.stub(:rename_index, ->(*) { raise "simulated index rename failure" }) { migration.migrate(:up) }
            end
          end
          indexes = connection.indexes(:decidim_users)
          assert_equal before.where, indexes.find { |entry| entry.name == AllowPhoneOnlyCitizenEmails::INDEX }.where
          assert_not(indexes.any? { |entry| entry.name == AllowPhoneOnlyCitizenEmails::TEMP_INDEX })
          migration.migrate(:up)
          assert(connection.indexes(:decidim_users).any? { |entry| entry.name == AllowPhoneOnlyCitizenEmails::INDEX && entry.unique })
        end

        test "database rollback refuses after two blank-email registrations without changing any citizens" do
          first = signup
          second = signup(phone: "+38765111222")
          require File.join(Decidim::Bih::Engine.root, "db/migrate/20261007130000_allow_phone_only_citizen_emails")
          assert_raises ActiveRecord::IrreversibleMigration do
            AllowPhoneOnlyCitizenEmails.new.migrate(:down)
          end
          assert first.reload
          assert second.reload
          index = ActiveRecord::Base.connection.indexes(:decidim_users).find { |entry| entry.name == AllowPhoneOnlyCitizenEmails::INDEX }
          assert_match(/email.*<>/, index.where)
        end

        test "fresh browser pending-number retry only resends to phone and never adopts identity or grants a session" do
          user = signup
          reset!
          host! @organization.host
          travel 61.seconds
          assert_no_difference -> { Decidim::User.count } do
            signup(name: "Intruder", newsletter: "0")
          end
          assert_redirected_to base
          assert_equal 2, Gateway.calls.size
          assert_equal ["sms"], Gateway.calls.last[:context][:channels]
          assert_equal "Nova Gradjanka", user.reload.name
          assert_not authorization(user).granted?
          assert_not request.session["warden.user.user.key"]
          get pending
          assert_redirected_to base
          # Cooldown and the same durable resend budget apply across browsers.
          signup
          assert_equal 2, Gateway.calls.size
          6.times do
            travel 61.seconds
            signup
          end
          assert_equal 6, Gateway.calls.size # initial plus five allowed resends
          TopicPreferences::TOPICS.each { |topic| assert_not TopicPreferences.enabled?(user, topic:) }
        end

        test "blank-email lifecycle skips both reminders and never deletes a verified citizen without komsiluk" do
          user = signup
          ResumeRegistrationEmailJob.perform_now(user.id, @organization.id)
          travel 5.days
          result = Registration::PendingLifecycle.sweep(organization: @organization, dry_run: false)
          assert_equal 0, result[:reminded]
          authorization(user).update!(granted_at: Time.current, verification_metadata: {})
          travel 3.days
          result = Registration::PendingLifecycle.sweep(organization: @organization, dry_run: false)
          assert_equal 0, result[:deleted]
          assert Decidim::User.exists?(user.id)
          assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob)
        end

        test "a forged email-confirmation request for a blank address queues nothing" do
          user = signup
          sign_in user
          assert_no_enqueued_jobs(only: Decidim::Bih::EmailConfirmationDeliveryJob) do
            post Decidim::Bih.public_path("potvrdi-email")
          end
          assert_redirected_to Decidim::Bih.public_path("moj-nalog")
          assert_nil user.reload.extended_data[EmailConfirmationsController::REQUESTED_AT_KEY]
        end
      end
    end
  end
end
