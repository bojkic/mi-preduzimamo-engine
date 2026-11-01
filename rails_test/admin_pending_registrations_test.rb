# frozen_string_literal: true

require_relative "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # The one admin surface of the pending-registration lifecycle: a dropdown
      # item on the participants list that re-sends the verification.
      class AdminPendingRegistrationsTest < ActionDispatch::IntegrationTest
        include ::Devise::Test::IntegrationHelpers

        PHONE = "+38765123456"

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

        setup do
          @organization = create_organization
          host! @organization.host
          @admin = FactoryBot.create(:user, :admin, :confirmed, organization: @organization)
          @stub = FactoryBot.create(:user, :confirmed, organization: @organization, sign_in_count: 0, name: "Pera Stub")
          Decidim::Authorization.create!(
            user: @stub, name: "sms",
            unique_id: Decidim::Bih::SmsAuthorization.unique_id_for(PHONE), granted_at: nil,
            verification_metadata: { "code_sent_at" => 1.day.ago.iso8601, "verification_code" => "111111" }
          )
          Decidim::Bih::LoginToken.issue!(user: @stub, purpose: "verify", phone: PHONE)
          @member = FactoryBot.create(:user, :confirmed, organization: @organization, name: "Mira Member")
          Decidim::Bih::Registration::OperatorResendThrottle.new(
            organization_id: @organization.id, authorization_id: @stub.id, challenge_version: "operator"
          ).reset!
          RecordingGateway.contexts = []
        end

        def resend_path(user) = "/admin/bih/pending-registrations/#{user.id}/resend"

        def with_recording_gateway
          previous = Decidim.sms_gateway_service
          Decidim.sms_gateway_service = RecordingGateway.name
          yield
        ensure
          Decidim.sms_gateway_service = previous
        end

        test "the participants list shows the resend item for a stub only" do
          sign_in @admin
          get "/admin/officializations"

          assert_response :success
          assert_select "form[action='#{resend_path(@stub)}']", 1
          assert_select "form[action='#{resend_path(@member)}']", 0
        end

        test "an admin can resend, is told so, and the send is audited" do
          sign_in @admin
          with_recording_gateway { post resend_path(@stub) }

          assert_redirected_to "/admin/officializations"
          assert_equal 1, RecordingGateway.contexts.size
          follow_redirect!
          assert_includes response.body, I18n.t("decidim.bih.admin.pending_registrations.resend.sent", locale: :sr)
          assert Decidim::Bih::OperatorAuditEvent.exists?(event_type: "registration_verification_resent", decidim_user_id: @admin.id)
        end

        test "an administrator of another organization cannot resend" do
          other = create_organization(host: "other-admin.example.org")
          foreign_admin = FactoryBot.create(:user, :admin, :confirmed, organization: other)
          sign_in foreign_admin

          assert_no_difference ["ActionMailer::Base.deliveries.size", "Decidim::Bih::OperatorAuditEvent.count"] do
            with_recording_gateway { post resend_path(@stub) }
          end

          assert_empty RecordingGateway.contexts
          assert_response :redirect
          assert_equal @organization.host, URI.parse(response.location).host
          assert_equal "/admin/", URI.parse(response.location).path
        end

        test "a blocked administrator cannot resend" do
          @admin.update!(blocked: true, blocked_at: Time.current)
          sign_in @admin

          assert_no_difference ["ActionMailer::Base.deliveries.size", "Decidim::Bih::OperatorAuditEvent.count"] do
            with_recording_gateway { post resend_path(@stub) }
          end

          assert_empty RecordingGateway.contexts
          assert_response :redirect
          assert_equal @organization.host, URI.parse(response.location).host
          assert_equal "/admin/", URI.parse(response.location).path
        end

        test "a member is refused with a flash, never a 500" do
          sign_in @admin
          with_recording_gateway { post resend_path(@member) }

          assert_redirected_to "/admin/officializations"
          assert_empty RecordingGateway.contexts
          follow_redirect!
          assert_includes response.body, I18n.t("decidim.bih.admin.pending_registrations.resend.not_a_stub", locale: :sr)
        end

        # ---- Phase 5 Task 5.4: one click, and it says what it cost --------

        test "the resend is a single POST with no confirmation step" do
          sign_in @admin
          with_recording_gateway { post resend_path(@stub) }

          assert_redirected_to "/admin/officializations"
          assert_equal 1, RecordingGateway.contexts.size
          assert_equal 1, ActionMailer::Base.deliveries.size
        end

        # The operator resend is deliberately NOT the citizen's failover chain.
        test "the SMS leg is SMS-only, never the ordinary failover chain" do
          sign_in @admin
          captured = nil
          # The original must be captured BEFORE the stub replaces it, or the
          # stub calls itself: `Klass.from_params` inside the block resolves to
          # the stub and recurses until the stack gives out.
          original = Decidim::Verifications::Sms::MobilePhoneForm.method(:from_params)
          Decidim::Verifications::Sms::MobilePhoneForm.stub(:from_params, lambda { |**attrs|
            captured = attrs
            original.call(**attrs)
          }) do
            with_recording_gateway { post resend_path(@stub) }
          end

          assert_equal ["sms"], captured[:delivery_channels]
        end

        test "the flash states scope, result and cost for ONE resend" do
          sign_in @admin
          with_recording_gateway { post resend_path(@stub) }
          follow_redirect!

          assert_includes response.body, I18n.t("decidim.bih.admin.pending_registrations.resend.sent", locale: :sr)
          assert_includes response.body,
                          I18n.t("decidim.bih.admin.pending_registrations.resend.one_sms_segment", count: 1, locale: :sr)
        end

        test "a second resend inside ten minutes is refused and nothing more is sent" do
          sign_in @admin
          with_recording_gateway do
            2.times { post resend_path(@stub) }
          end

          assert_equal 1, RecordingGateway.contexts.size
          follow_redirect!
          assert_includes response.body, I18n.t("decidim.bih.admin.pending_registrations.resend.throttled", locale: :sr)
        end

        test "the resend grants no authorization and no points" do
          sign_in @admin
          assert_no_difference ["Decidim::Authorization.where.not(granted_at: nil).count",
                                "Decidim::Bih::Goodwill::Transaction.count"] do
            with_recording_gateway { post resend_path(@stub) }
          end
        end

        # A throttle that cannot be read must refuse, not wave the send
        # through - one operator click must never become an unbounded sender.
        test "the throttle fails CLOSED when its store is unavailable" do
          sign_in @admin
          Decidim::Bih::Registration::OperatorResendThrottle.stub(:new, ->(**) { raise Redis::BaseError, "down" }) do
            assert_raises(Redis::BaseError) { with_recording_gateway { post resend_path(@stub) } }
          end
          assert_empty RecordingGateway.contexts
        end

        test "a non-admin cannot resend" do
          sign_in @member
          with_recording_gateway { post resend_path(@stub) }

          assert_response :redirect
          assert_empty RecordingGateway.contexts
          assert_empty Decidim::Bih::OperatorAuditEvent.where(event_type: "registration_verification_resent")
        end
      end
    end
  end
end
