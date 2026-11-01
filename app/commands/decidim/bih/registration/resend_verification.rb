# frozen_string_literal: true

module Decidim
  module Bih
    module Registration
      # An operator re-sends a stuck registration's verification: the resume
      # e-mail with a fresh 7-day token AND an SMS with a fresh link and code,
      # through the same Decidim step the pending page's "send again" uses.
      # Nothing here grants a phone — the grant stays in
      # PhoneVerification::Complete when the citizen taps or types.
      #
      # Used by the rake task and the admin participants list. The citizen's
      # own resend budget is untouched; operators get one send per citizen per
      # ten minutes (OperatorResendThrottle) and every send is audited with
      # ids and flags only — never the address, never the number.
      class ResendVerification
        # What the operator surface renders. `sms_segments` is the COST of one
        # resend: the gateway sends exactly one GSM-7 message, so the number is
        # a constant here rather than a guess made in a view.
        #
        # `next_allowed_at` is nil when the throttle could not say - a nil must
        # stay "we do not know" rather than becoming a time that invites an
        # immediate retry.
        Result = Struct.new(:status, :email, :sms, :next_allowed_at, :sms_segments) do
          def sent? = status == :sent

          def throttled? = status == :throttled
        end

        # One resend is one e-mail plus one single-segment SMS. Never a
        # failover chain: `send_sms` passes `delivery_channels: ["sms"]`.
        SMS_SEGMENTS_PER_RESEND = 1

        def self.call(user, actor:, source:) = new(user, actor:, source:).call

        def initialize(user, actor:, source:)
          @user = user
          @actor = actor
          @source = source.to_s
        end

        # :sent, :not_a_stub, :no_number, :throttled or :failed (the provider
        # refused the SMS; nothing was spent, so a retry is immediate).
        def call
          return Result.new(:not_a_stub, false, false, nil, 0) unless PendingLifecycle.stub?(@user)

          phone = phone_on_record
          return Result.new(:no_number, false, false, nil, 0) if phone.blank?
          return Result.new(:throttled, false, false, next_allowed_at, 0) if throttle.exhausted?

          email_sent = send_resume_email
          sms_sent = send_sms(phone)
          return Result.new(:failed, email_sent, false, nil, 0) unless sms_sent

          throttle.spend!
          Decidim::Bih::OperatorAuditEvent.record!(
            organization: @user.organization, actor: @actor,
            event_type: "registration_verification_resent",
            metadata: { "source" => @source, "target_user_id" => @user.id, "email_sent" => email_sent, "sms_sent" => true }
          )
          Result.new(:sent, email_sent, true, next_allowed_at, SMS_SEGMENTS_PER_RESEND)
        end

        private

        # When the next operator resend becomes possible. Read-only, and nil
        # when the throttle cannot say - including when a test double does not
        # answer the question at all.
        def next_allowed_at
          return nil unless throttle.respond_to?(:retry_after_seconds)

          seconds = throttle.retry_after_seconds
          seconds ? Time.current + seconds : nil
        end

        # The newest verify token keeps the number in clear; the authorization
        # row only holds a hash. Same rule as PhoneVerificationActions#phone_on_record.
        def phone_on_record
          Decidim::Bih::LoginToken.where(user: @user, purpose: "verify")
                                  .order(created_at: :desc, id: :desc).first&.phone
        end

        def throttle
          @throttle ||= OperatorResendThrottle.new(
            organization_id: @user.organization.id, authorization_id: @user.id, challenge_version: "operator"
          )
        end

        def send_resume_email
          return false if @user.email.blank?

          Decidim::Bih::RegistrationMailer.resume(@user, PendingAccess.mint_email(@user)).deliver_now
          true
        rescue StandardError => e
          Rails.logger.warn("[registracija] operator resume e-mail failed for user #{@user.id}: #{e.class}")
          false
        end

        # Decidim's own "send the code" step on the citizen's pending `sms`
        # row: it rewrites the code and code_sent_at, and the engine's gateway
        # mints a fresh verify link. The citizen is a from_params ATTRIBUTE —
        # with_context(user:) would leave form.user nil and the gateway would
        # refuse to mint a link at all (see the with_context trap).
        def send_sms(phone)
          authorization = Decidim::Authorization.find_by(user: @user, name: "sms")
          form = Decidim::Verifications::Sms::MobilePhoneForm.from_params(
            mobile_phone_number: phone, delivery_channels: ["sms"], user: @user
          ).with_context(current_organization: @user.organization)
          outcome = false
          Decidim::Verifications::PerformAuthorizationStep.call(authorization, form) do
            on(:ok) { outcome = true }
            on(:invalid) { outcome = false }
          end
          outcome
        end
      end
    end
  end
end
