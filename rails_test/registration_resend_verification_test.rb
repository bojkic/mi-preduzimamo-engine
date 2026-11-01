# frozen_string_literal: true

require_relative "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The operator re-send: resume e-mail + SMS-only replay of the send step,
      # throttled, audited, never granting anything.
      class RegistrationResendVerificationTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper
        include ActionMailer::TestHelper

        COMMAND = Decidim::Bih::Registration::ResendVerification
        PHONE = "+38765123456"

        # Records what the engine's gateway would have been asked to send.
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

        class RefusingGateway
          def initialize(*) = nil

          def deliver_code = false
        end

        setup do
          @organization = create_organization
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @stub = pending_citizen!(PHONE)
          Decidim::Bih::LoginToken.where(user: @stub).update_all(expires_at: 1.day.ago) # rubocop:disable Rails/SkipsModelValidations
          throttle_for(@stub).reset!
          RecordingGateway.contexts = []
        end

        def pending_citizen!(phone)
          user = FactoryBot.create(:user, :confirmed, organization: @organization, sign_in_count: 0)
          Decidim::Authorization.create!(
            user:, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(phone),
            granted_at: nil,
            verification_metadata: { "code_sent_at" => 2.days.ago.iso8601, "verification_code" => "111111" }
          )
          Decidim::Bih::LoginToken.issue!(user:, purpose: "verify", phone:)
          user
        end

        def throttle_for(user)
          Decidim::Bih::Registration::OperatorResendThrottle.new(
            organization_id: @organization.id, authorization_id: user.id, challenge_version: "operator"
          )
        end

        def with_gateway(klass)
          previous = Decidim.sms_gateway_service
          Decidim.sms_gateway_service = klass.name
          yield
        ensure
          Decidim.sms_gateway_service = previous
        end

        test "sends the resume e-mail and an SMS with a fresh link, audits it, then throttles" do
          result = nil
          assert_emails(1) do
            with_gateway(RecordingGateway) { result = COMMAND.call(@stub, actor: @admin, source: "admin") }
          end

          assert_equal :sent, result.status
          assert result.email
          assert result.sms
          assert_equal 1, RecordingGateway.contexts.size
          assert_equal ["sms"], Array(RecordingGateway.contexts.first[:channels])
          # The recording gateway mints no link (the real one does, inside
          # magic_link_url); what proves the send step ran is Decidim's own
          # rewrite of the code and its timestamp on the pending row.
          refute_equal "111111", Decidim::Authorization.find_by(user: @stub, name: "sms").verification_metadata["verification_code"],
                       "a fresh code was written to the pending row"
          refute Decidim::Authorization.find_by(user: @stub, name: "sms").granted?, "nothing was granted"

          event = Decidim::Bih::OperatorAuditEvent.where(event_type: "registration_verification_resent").last
          assert_equal @admin.id, event.decidim_user_id
          assert_equal "admin", event.metadata["source"]
          assert_equal @stub.id, event.metadata["target_user_id"]
          refute_includes event.metadata.to_json, PHONE
          refute_includes event.metadata.to_json, @stub.email

          with_gateway(RecordingGateway) do
            assert_equal :throttled, COMMAND.call(@stub, actor: @admin, source: "admin").status
          end
        end

        test "a refused SMS is reported as failed and spends nothing" do
          result = with_gateway(RefusingGateway) { COMMAND.call(@stub, actor: nil, source: "rake") }
          assert_equal :failed, result.status
          refute throttle_for(@stub).exhausted?, "a refusal must leave the operator free to retry"
          assert_empty Decidim::Bih::OperatorAuditEvent.where(event_type: "registration_verification_resent")
        end

        test "refuses a verified account and a stub with no number on record" do
          Decidim::Authorization.find_by(user: @stub, name: "sms").update!(granted_at: Time.current, verification_metadata: {})
          assert_equal :not_a_stub, COMMAND.call(@stub, actor: nil, source: "rake").status

          bare = FactoryBot.create(:user, :confirmed, organization: @organization, sign_in_count: 0)
          Decidim::Authorization.create!(
            user: bare, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for("+38765000001"), granted_at: nil
          )
          assert_equal :no_number, COMMAND.call(bare, actor: nil, source: "rake").status
        end
      end
    end
  end
end
