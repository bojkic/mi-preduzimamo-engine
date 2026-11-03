# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # Spec 9.2: an e-mail address the citizen never proved is not a recovery
      # channel. Phone-first sign-up sets confirmed_at without an e-mail round
      # trip, so Devise alone would mail a reset link to whatever address was
      # typed at sign-up — possibly a stranger's.
      class PasswordResetGuardTest < ActionDispatch::IntegrationTest
        include ActiveJob::TestHelper

        NEW_PASSWORD = "Another-strong-password-2026"

        setup do
          @organization = create_organization
          host! @organization.host
          Decidim::Bih.phone_first_registration = true
          Decidim::Bih.phone_first_registration_since = 1.day.ago.utc.to_s
          # :confirmed sets confirmed_at now, i.e. AFTER the cutoff, so it is
          # not grandfathered and the address counts as unproven.
          @citizen = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        teardown do
          Decidim::Bih.phone_first_registration = false
          Decidim::Bih.phone_first_registration_since = nil
        end

        test "requesting a reset for an unproven address sends nothing but answers like success" do
          assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
            post "/sr/users/password", params: { user: { email: @citizen.email } }
          end

          assert_response :redirect
          assert_nil @citizen.reload.reset_password_token
        end

        # The endpoint must not become an account oracle: a refused request has
        # to look exactly like a request for an address that does not exist.
        test "the refusal is indistinguishable from a reset for an unknown address" do
          post "/sr/users/password", params: { user: { email: @citizen.email } }
          refused = [response.status, response.location, flash[:notice], flash[:alert]]

          post "/sr/users/password", params: { user: { email: "niko-#{SecureRandom.hex(6)}@example.org" } }
          unknown = [response.status, response.location, flash[:notice], flash[:alert]]

          assert_equal unknown, refused
        end

        test "requesting a reset for a proven address still works" do
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)

          assert_enqueued_jobs(1, only: ActionMailer::MailDeliveryJob) do
            post "/sr/users/password", params: { user: { email: @citizen.email } }
          end

          assert @citizen.reload.reset_password_token.present?
        end

        test "consuming a reset token for an address that lost its proof is refused" do
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)
          raw = @citizen.send_reset_password_instructions
          # rubocop:disable Rails/SkipsModelValidations
          @citizen.update_columns(email: "promijenjen-#{@citizen.id}@example.org") # proof no longer matches
          # rubocop:enable Rails/SkipsModelValidations

          put "/sr/users/password", params: { user: { reset_password_token: raw, password: NEW_PASSWORD } }

          assert_redirected_to "/sr/users/password/new"
          assert_equal I18n.t("decidim.bih.passwords.unconfirmed_email", locale: :sr), flash[:alert]
          refute @citizen.reload.valid_password?(NEW_PASSWORD)
        end

        # With the flag off the engine must be invisible here. A stock host
        # still has the cutoff unset OR set-but-not-yet-flipped, and in both
        # shapes Decidim's own reset has to work exactly as it always did —
        # EmailConfirmation must not even be consulted.
        test "with phone-first off a confirmed account resets the stock way" do
          Decidim::Bih.phone_first_registration = false
          # Cutoff deliberately LEFT SET (1.day.ago): the operator configured the
          # date but has not flipped the switch yet. EmailConfirmation would call
          # this account unproven; the guard must not care.
          assert_enqueued_jobs(1, only: ActionMailer::MailDeliveryJob) do
            post "/sr/users/password", params: { user: { email: @citizen.email } }
          end

          assert @citizen.reload.reset_password_token.present?
        end

        # The case the guard would break most quietly: a stock Decidim host has
        # registered-but-never-confirmed accounts, and they are entitled to a
        # reset mail. confirmed_at IS NULL is never proof under
        # EmailConfirmation, so only the flag check keeps this working.
        test "with phone-first off an unconfirmed account resets the stock way" do
          Decidim::Bih.phone_first_registration = false
          Decidim::Bih.phone_first_registration_since = nil
          pending = FactoryBot.create(:user, organization: @organization)

          refute pending.confirmed?
          assert_enqueued_jobs(1, only: ActionMailer::MailDeliveryJob) do
            post "/sr/users/password", params: { user: { email: pending.email } }
          end

          assert pending.reload.reset_password_token.present?
        end

        # Control for the test above: the guard must not break the ordinary
        # reset, or the refusal proves nothing.
        test "consuming a reset token for a proven address still sets the password" do
          Decidim::Bih::EmailConfirmation.mark_confirmed!(@citizen)
          raw = @citizen.send_reset_password_instructions

          put "/sr/users/password", params: { user: { reset_password_token: raw, password: NEW_PASSWORD } }

          assert @citizen.reload.valid_password?(NEW_PASSWORD)
        end
      end
    end
  end
end
