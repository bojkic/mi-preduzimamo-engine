# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Task 1.2 storage contracts.
      #
      # Four separate concerns, deliberately four separate stores: what a
      # citizen currently wants, how that came to be, what a transport refuses
      # to carry, and what the organization's default policy is. A provider STOP
      # is not a topic choice, and an organization default is not an acceptance
      # click; neither may be able to impersonate the other.
      # rubocop:disable Rails/SkipsModelValidations -- `insert!` is deliberate:
      # these cases prove the DATABASE constraint, and a validation would mask
      # it. Two racing workers both pass validations; only the index stops them.
      class MessagingPreferenceTest < ActiveSupport::TestCase
        setup do
          @organization = create_organization
          @other_organization = create_organization
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
          @stranger = FactoryBot.create(:user, :confirmed, organization: @other_organization)
        end

        # ---- current preference ------------------------------------------

        test "an explicit allowed choice is stored with its origin and time" do
          preference = Messaging::Preference.create!(
            organization: @organization, user: @citizen, topic: "report_updates",
            state: "allowed", source: "account", policy_version: "mi-2026-09-14",
            change_id: SecureRandom.uuid, changed_at: Time.current
          )

          assert_predicate preference, :allowed?
          assert_not preference.blocked?
          assert_equal "account", preference.source
          assert_not_nil preference.changed_at
        end

        test "an explicit blocked choice is a stored value, not an absent row" do
          preference = Messaging::Preference.create!(
            organization: @organization, user: @citizen, topic: "community_news",
            state: "blocked", source: "account", policy_version: "mi-2026-09-14",
            change_id: SecureRandom.uuid, changed_at: Time.current
          )

          assert_predicate preference, :blocked?
          assert_equal 1, Messaging::Preference.where(user: @citizen).count
        end

        test "organization_default is a supported source and is not relabelled as an account choice" do
          preference = Messaging::Preference.create!(
            organization: @organization, user: @citizen, topic: "report_updates",
            state: "allowed", source: "organization_default", policy_version: "mi-2026-09-14",
            change_id: SecureRandom.uuid, changed_at: Time.current
          )

          assert_equal "organization_default", preference.source
          assert_not preference.personal_choice?
        end

        test "a preference for a user in another organization is rejected" do
          preference = Messaging::Preference.new(
            organization: @organization, user: @stranger, topic: "report_updates",
            state: "allowed", source: "account", policy_version: "mi-2026-09-14",
            change_id: SecureRandom.uuid, changed_at: Time.current
          )

          assert_not preference.valid?
          assert_includes preference.errors.attribute_names, :user
        end

        test "unrecognised topic, state and source values are refused" do
          [:topic, :state, :source].each do |attribute|
            attributes = {
              organization: @organization, user: @citizen, topic: "report_updates",
              state: "allowed", source: "account", policy_version: "mi-2026-09-14",
              change_id: SecureRandom.uuid, changed_at: Time.current
            }
            attributes[attribute] = "nonsense"

            assert_not Messaging::Preference.new(**attributes).valid?, "#{attribute} should be constrained"
          end
        end

        test "current preference identity has no channel dimension" do
          assert_not_includes Messaging::Preference.column_names, "channel"
        end

        test "the database itself refuses a second row for the same identity" do
          attributes = {
            decidim_organization_id: @organization.id, decidim_user_id: @citizen.id,
            topic: "report_updates", state: "allowed", source: "account",
            policy_version: "mi-2026-09-14", change_id: SecureRandom.uuid, changed_at: Time.current,
            created_at: Time.current, updated_at: Time.current
          }
          Messaging::Preference.insert!(attributes)

          # Validations are not the protection here: two workers racing would
          # both pass them. The unique index is.
          assert_raises(ActiveRecord::RecordNotUnique) do
            Messaging::Preference.insert!(attributes.merge(change_id: SecureRandom.uuid))
          end
        end

        test "the same topic may be stored once per citizen" do
          other = FactoryBot.create(:user, :confirmed, organization: @organization)
          [@citizen, other].each do |user|
            Messaging::Preference.create!(
              organization: @organization, user:, topic: "report_updates",
              state: "allowed", source: "account", policy_version: "mi-2026-09-14",
              change_id: SecureRandom.uuid, changed_at: Time.current
            )
          end

          assert_equal 2, Messaging::Preference.where(organization: @organization).count
        end

        test "deleting a citizen removes their preferences but not the organization policy" do
          Messaging::Preference.create!(
            organization: @organization, user: @citizen, topic: "report_updates",
            state: "allowed", source: "account", policy_version: "mi-2026-09-14",
            change_id: SecureRandom.uuid, changed_at: Time.current
          )
          Messaging::OrganizationPolicy.create!(
            organization: @organization, policy_version: "mi-2026-09-14", effective_from: Time.current, active: true
          )

          # Deleting the row directly, rather than through Decidim's destroy
          # callbacks, is the point: this asserts the DATABASE cascade, which is
          # what actually protects an anonymisation run.
          Decidim::User.where(id: @citizen.id).delete_all

          assert_equal 0, Messaging::Preference.where(decidim_user_id: @citizen.id).count
          assert_equal 1, Messaging::OrganizationPolicy.where(organization: @organization).count
        end

        # ---- change events -------------------------------------------------

        test "a change event records the previous and new state with a real actor class" do
          event = Messaging::PreferenceChange.create!(
            organization: @organization, user: @citizen, topic: "report_updates", channel: "viber",
            previous_state: nil, new_state: "allowed", previous_source: nil, source: "organization_default",
            actor_type: "organization_policy", operation: "organization_default",
            change_id: SecureRandom.uuid, policy_version: "mi-2026-09-14", recorded_at: Time.current
          )

          assert_nil event.previous_state, "an absent previous value must stay absent, not become false"
          assert_equal "allowed", event.new_state
          assert_equal "organization_policy", event.actor_type
        end

        test "an unknown historical origin is stored as unknown rather than invented" do
          event = Messaging::PreferenceChange.create!(
            organization: @organization, user: @citizen, topic: "community_news", channel: "viber",
            previous_state: nil, new_state: "allowed", source: "unknown",
            actor_type: "system_import", operation: "import",
            change_id: SecureRandom.uuid, policy_version: "mi-2026-09-14", recorded_at: Time.current
          )

          assert_equal "unknown", event.source
          assert_equal "import", event.operation
        end

        test "change events carry no message content, code or private body column" do
          forbidden = %w(body text payload content message code otp token)
          columns = Messaging::PreferenceChange.column_names

          forbidden.each do |name|
            assert_not_includes columns, name
            assert_empty columns.grep(/#{name}/), "change events must not collect #{name}"
          end
        end

        test "change events are append-only from the model's point of view" do
          event = Messaging::PreferenceChange.create!(
            organization: @organization, user: @citizen, topic: "report_updates", channel: "viber",
            previous_state: nil, new_state: "allowed", source: "account", actor_type: "citizen",
            operation: "set", change_id: SecureRandom.uuid, policy_version: "mi-2026-09-14",
            recorded_at: Time.current
          )

          assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(new_state: "blocked") }
        end

        test "an unrecognised actor class or operation is refused" do
          base = {
            organization: @organization, user: @citizen, topic: "report_updates", channel: "viber",
            previous_state: nil, new_state: "allowed", source: "account",
            actor_type: "citizen", operation: "set", change_id: SecureRandom.uuid,
            policy_version: "mi-2026-09-14", recorded_at: Time.current
          }

          assert_not Messaging::PreferenceChange.new(**base, actor_type: "the_weather").valid?
          assert_not Messaging::PreferenceChange.new(**base, operation: "improvise").valid?
        end

        # ---- transport suppression -----------------------------------------

        test "provider suppression is a separate store from the topic choice" do
          Messaging::Preference.create!(
            organization: @organization, user: @citizen, topic: "report_updates",
            state: "allowed", source: "account", policy_version: "mi-2026-09-14",
            change_id: SecureRandom.uuid, changed_at: Time.current
          )
          suppression = Messaging::Suppression.create!(
            organization: @organization, provider: "infobip", channel: "viber",
            destination_kind: "phone", destination_digest: Digest::SHA256.hexdigest("+38765000000"),
            address_version: 1, reason: "provider_opt_out", source: "provider_webhook",
            suppressed_at: Time.current, user: @citizen
          )

          assert_predicate suppression, :active?
          assert_equal 1, Messaging::Preference.where(user: @citizen).count,
                       "a suppression must not be written into the preference table"
        end

        test "a suppression can exist without any account at all" do
          suppression = Messaging::Suppression.create!(
            organization: @organization, provider: "infobip", channel: "whatsapp",
            destination_kind: "channel_identity", destination_digest: "d" * 64,
            address_version: 1, reason: "provider_opt_out", source: "provider_webhook",
            suppressed_at: Time.current
          )

          assert_nil suppression.decidim_user_id
          assert_predicate suppression, :valid?
        end

        test "a new address version is a new row and does not inherit the old failure" do
          digest_old = Digest::SHA256.hexdigest("+38765000000")
          digest_new = Digest::SHA256.hexdigest("+38765111111")
          Messaging::Suppression.create!(
            organization: @organization, provider: "infobip", channel: "viber", destination_kind: "phone",
            destination_digest: digest_old, address_version: 1, reason: "hard_bounce",
            source: "provider_webhook", suppressed_at: Time.current, user: @citizen
          )

          assert_nil Messaging::Suppression.active_for(
            organization: @organization, provider: "infobip", channel: "viber", destination_digest: digest_new
          )
          assert_not_nil Messaging::Suppression.active_for(
            organization: @organization, provider: "infobip", channel: "viber", destination_digest: digest_old
          )
        end

        test "reactivation is recorded with its evidence rather than deleting the row" do
          suppression = Messaging::Suppression.create!(
            organization: @organization, provider: "infobip", channel: "viber", destination_kind: "phone",
            destination_digest: Digest::SHA256.hexdigest("+38765000000"), address_version: 1,
            reason: "provider_opt_out", source: "provider_webhook", suppressed_at: Time.current, user: @citizen
          )
          suppression.update!(reactivated_at: Time.current, reactivation_evidence: "operator_case:1234")

          assert_not suppression.active?
          assert_equal 1, Messaging::Suppression.where(organization: @organization).count
          assert_equal "provider_opt_out", suppression.reason, "the original reason stays readable"
        end

        test "the database refuses a duplicate suppression identity" do
          attributes = {
            decidim_organization_id: @organization.id, provider: "infobip", channel: "viber",
            destination_kind: "phone", destination_digest: "e" * 64, address_version: 1,
            reason: "provider_opt_out", source: "provider_webhook", suppressed_at: Time.current,
            created_at: Time.current, updated_at: Time.current
          }
          Messaging::Suppression.insert!(attributes)

          assert_raises(ActiveRecord::RecordNotUnique) { Messaging::Suppression.insert!(attributes) }
        end

        test "an unrecognised suppression reason or destination kind is refused" do
          base = {
            organization: @organization, provider: "infobip", channel: "viber", destination_kind: "phone",
            destination_digest: "f" * 64, address_version: 1, reason: "provider_opt_out",
            source: "provider_webhook", suppressed_at: Time.current
          }

          assert_not Messaging::Suppression.new(**base, reason: "felt_like_it").valid?
          assert_not Messaging::Suppression.new(**base, destination_kind: "carrier_pigeon").valid?
        end

        # ---- organization policy ---------------------------------------------

        test "organization policy is versioned and scoped to its tenant" do
          Messaging::OrganizationPolicy.create!(
            organization: @organization, policy_version: "mi-2026-09-14", effective_from: Time.current,
            active: true, defaults: { "report_updates" => { "viber" => "allowed" } },
            supported_combinations: { "report_updates" => %w(viber whatsapp) }
          )

          assert_equal "allowed", Messaging::OrganizationPolicy.active_for(@organization)
                                                               .defaults.dig("report_updates", "viber")
          assert_nil Messaging::OrganizationPolicy.active_for(@other_organization),
                     "a reusable engine default must not opt another host into this policy"
        end

        test "the same policy version cannot be stored twice for one organization" do
          attributes = {
            decidim_organization_id: @organization.id, policy_version: "mi-2026-09-14",
            effective_from: Time.current, active: true, defaults: {}, supported_combinations: {},
            created_at: Time.current, updated_at: Time.current
          }
          Messaging::OrganizationPolicy.insert!(attributes)

          assert_raises(ActiveRecord::RecordNotUnique) { Messaging::OrganizationPolicy.insert!(attributes) }
        end

        # ---- intent / attempt structure ---------------------------------------

        test "an intent can address a recipient that has no account" do
          intent = Messaging::Intent.create!(
            organization: @organization, message_class: "report.reporter_status_email",
            recipient_kind: "anonymous_report_contact", recipient_reference: "a" * 64,
            correlation_key: "report:1:status:u_obradi", deduplication_scope: "report_status",
            policy_version: "mi-2026-09-14", eligibility_version: "mi-2026-09-14", mode: "shadow"
          )

          assert_nil intent.decidim_user_id
          assert_predicate intent, :valid?
        end

        test "one intent carries many attempts, including one per device" do
          intent = Messaging::Intent.create!(
            organization: @organization, message_class: "report.case_message_to_author",
            recipient_kind: "account", user: @citizen, correlation_key: "report:1:message:9",
            deduplication_scope: "report_case_message", policy_version: "mi-2026-09-14",
            eligibility_version: "mi-2026-09-14", mode: "shadow"
          )
          2.times do |index|
            intent.attempts.create!(channel_group: "push", channel: "push", status: "queued",
                                    destination_version: "device-#{index}")
          end
          intent.attempts.create!(channel_group: "external_copy", channel: "whatsapp", status: "queued")

          assert_equal 3, intent.attempts.count
          assert_equal 2, intent.attempts.where(channel: "push").count
        end

        test "an intent is linked to the legacy account-notification record rather than replacing it" do
          notification = AccountNotification.create!(
            organization: @organization, user: @citizen, topic: "report_updates",
            deduplication_digest: Digest::SHA256.hexdigest("intent-link-test"),
            expires_at: 1.hour.from_now, payload: { text: "x", channels: ["viber"] }
          )
          intent = Messaging::Intent.create!(
            organization: @organization, message_class: "report.author_external_copy",
            recipient_kind: "account", user: @citizen, correlation_key: "report:2:status:rijeseno",
            deduplication_scope: "report_status", policy_version: "mi-2026-09-14",
            eligibility_version: "mi-2026-09-14", mode: "shadow", account_notification: notification
          )

          assert_equal notification.id, intent.reload.decidim_bih_account_notification_id
          assert_equal 1, AccountNotification.where(id: notification.id).count
        end

        test "the same business event cannot produce two intents in one deduplication scope" do
          attributes = {
            decidim_organization_id: @organization.id, message_class: "report.author_external_copy",
            recipient_kind: "account", decidim_user_id: @citizen.id,
            correlation_key: "report:3:status:rijeseno", deduplication_scope: "report_status",
            policy_version: "mi-2026-09-14", eligibility_version: "mi-2026-09-14", mode: "shadow",
            status: "planned", created_at: Time.current, updated_at: Time.current
          }
          Messaging::Intent.insert!(attributes)

          assert_raises(ActiveRecord::RecordNotUnique) { Messaging::Intent.insert!(attributes) }
        end

        test "attempt outcomes distinguish acceptance, delivery, uncertainty and expiry" do
          intent = Messaging::Intent.create!(
            organization: @organization, message_class: "report.author_external_copy",
            recipient_kind: "account", user: @citizen, correlation_key: "report:4:status:rijeseno",
            deduplication_scope: "report_status", policy_version: "mi-2026-09-14",
            eligibility_version: "mi-2026-09-14", mode: "shadow"
          )

          %w(queued claimed accepted delivered uncertain skipped failed expired).each do |status|
            attempt = intent.attempts.new(channel_group: "external_copy", channel: "viber", status:)

            assert_predicate attempt, :valid?, "#{status} must be a recognised outcome"
          end
          assert_not intent.attempts.new(channel_group: "external_copy", channel: "viber", status: "read").valid?,
                     "a read marker is channel-specific and is not a delivery outcome here"
        end

        test "phase 1 intents are shadow only and cannot claim to be authoritative" do
          intent = Messaging::Intent.new(
            organization: @organization, message_class: "report.author_external_copy",
            recipient_kind: "account", user: @citizen, correlation_key: "report:5:status:rijeseno",
            deduplication_scope: "report_status", policy_version: "mi-2026-09-14",
            eligibility_version: "mi-2026-09-14", mode: "authoritative"
          )

          assert_not intent.valid?
          assert_includes intent.errors.attribute_names, :mode
        end

        test "the legacy account-notification table is untouched by the new storage" do
          assert_equal %w(pending sending accepted rejected failed unknown skipped delivered).sort,
                       AccountNotification.validators_on(:status).first.options.fetch(:in).sort
        end
      end
      # rubocop:enable Rails/SkipsModelValidations
    end
  end
end
