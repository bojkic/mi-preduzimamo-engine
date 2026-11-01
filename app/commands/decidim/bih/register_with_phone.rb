# frozen_string_literal: true

module Decidim
  module Bih
    # One-step registration (spec 5.3). Opens an active, password-less account,
    # records the komšiluk without paying for it and writes the pending `sms`
    # row — all in one transaction — and only THEN starts Decidim's own SMS
    # step, which mints the one-tap verify link and sends it Viber → WhatsApp
    # → SMS. It schedules the "one more step" reminder and hands the controller
    # the SESSION pending token.
    #
    # The citizen is deliberately NOT signed in here: nothing in this request
    # proves the phone. Signing in happens when the link is consumed or the
    # code is confirmed, and goes through CompletesPhoneAuthentication like
    # every other phone sign-in on this platform.
    #
    # Points are not paid here either. Registration is worth 20 (verification
    # 10 + komsiluk_selected 10) and every one of them is paid by the `sms`
    # grant hook (authorization_referral_override.rb), i.e. by a phone somebody
    # actually answered. An account that never verifies earns nothing.
    #
    # Broadcasts:
    #   :ok(user, session_token)              account open, message on its way
    #   :delivery_failed(user, session_token) account open, provider refused
    #                                         or fell over; the citizen can
    #                                         resend from the pending page
    #   :invalid                              nothing was created — the form
    #                                         was wrong, the address belongs to
    #                                         an account that may not be
    #                                         claimed, or the number is already
    #                                         being verified by somebody else
    class RegisterWithPhone < Decidim::Command
      # Long enough that the citizen who is simply reading the SMS is not
      # nagged, short enough to catch the one who put the phone down.
      RESUME_EMAIL_DELAY = 15.minutes

      # Whether an existing account may be CLAIMED by whoever registers with
      # its e-mail address (see #existing_account for why that is a thing at
      # all).
      #
      # Adoption happens without the invitation token, so it is restricted to
      # rows that hold nothing worth stealing: an unaccepted invitation, never
      # signed in, no authorization already earned, and never an administrator,
      # platform-role or SPACE-role holder, private-space member, officialized,
      # managed, blocked or deleted account. An invited admin who is told "this
      # address already has an account" is a small annoyance; an invited admin
      # whose account can be claimed by anyone who guesses the address is a
      # privilege escalation.
      def self.adoptable?(user)
        return false unless user.is_a?(Decidim::User)
        return false unless unaccepted_invitation?(user)
        return false if privileged?(user)

        # Nothing has been proven on this row yet, so nothing is being taken
        # away from whoever was invited.
        !Decidim::Authorization.exists?(user:)
      end

      # A row an invitation created and nobody has acted on: still addressed to
      # its recipient, never signed in, never accepted.
      def self.unaccepted_invitation?(user)
        user.invitation_token.present? && user.invitation_accepted_at.nil? && user.sign_in_count.to_i.zero?
      end
      private_class_method :unaccepted_invitation?

      # Space-level authority lives in its own tables, so `admin?` and `roles`
      # say nothing about it: Decidim invites a process or assembly
      # administrator with `admin: false` and a role row, and a private-space
      # member the same way. Only the models this platform actually installs
      # are consulted — conferences and initiatives are not — so a name that
      # does not resolve is skipped rather than raising.
      SPACE_ROLE_MODELS = %w(
        Decidim::ParticipatoryProcessUserRole
        Decidim::AssemblyUserRole
        Decidim::ParticipatorySpacePrivateUser
      ).freeze

      # Everything that makes a row worth stealing, or not a plain citizen's.
      def self.privileged?(user)
        user.admin? || user.roles.present? || user.officialized_at.present? ||
          user.managed? || user.blocked? || user.deleted? || space_role_holder?(user)
      end
      private_class_method :privileged?

      def self.space_role_holder?(user)
        SPACE_ROLE_MODELS.any? do |name|
          model = name.safe_constantize
          model.present? && model.exists?(decidim_user_id: user.id)
        end
      end
      private_class_method :space_role_holder?

      def initialize(form)
        @form = form
      end

      def call
        return broadcast(:invalid) if form.invalid?

        @existing = existing_account
        return refuse_taken_email! if @existing && !self.class.adoptable?(@existing)
        return handle_pending_phone! if phone_in_verification?

        # Commit first, send second. Everything the citizen must still have
        # when the provider lets us down — the account, the komšiluk and the
        # PENDING sms row that makes the returned token resolve — is committed
        # before a single message is attempted.
        transaction do
          release_abandoned_phone_claims!
          @user = @existing || Decidim::User.new(organization:)
          persist_citizen!
          assign_komsiluk! unless form.simplified?
          @authorization = persist_pending_authorization!
        end

        enqueue_resume_email!

        token = Decidim::Bih::Registration::PendingAccess.mint_session(@user)
        deliver_verification! ? broadcast(:ok, @user, token) : broadcast(:delivery_failed, @user, token)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        refuse_unexpectedly!(e)
      end

      private

      attr_reader :form

      def handle_pending_phone!
        form.simplified? ? recover_pending_phone! : refuse_phone_pending!
      end

      def enqueue_resume_email!
        return if @user.email.blank?

        Decidim::Bih::ResumeRegistrationEmailJob.set(wait: RESUME_EMAIL_DELAY).perform_later(@user.id, organization.id)
      end

      def organization = form.current_organization

      # An invitation that was never accepted must not turn "open an account"
      # into "an account with this e-mail already exists": the invited citizen
      # has no verified phone, so that message sends them to a sign-in they
      # cannot complete. Registering with the invited address claims the row
      # instead of duplicating it — a duplicate is impossible anyway, since
      # Decidim::User validates e-mail uniqueness per organization.
      # The form already downcases the address and Devise stores it that way,
      # so this hits (organization, email) directly rather than wrapping the
      # column in LOWER() and losing the index.
      def existing_account
        return if form.email.blank?

        Decidim::User.find_by(organization:, email: form.email.downcase, deleted_at: nil)
      end

      # Somebody else is already in the middle of verifying this number, RIGHT
      # NOW: a pending claim whose code could still be answered. Sending a
      # second one would race two accounts for one phone, and Decidim's own
      # duplicate check would refuse the grant at the end anyway — so the
      # citizen is told before an account and a message exist, rather than
      # after. The copy promises "try again in 24 hours", and VERIFY_TTL —
      # the bound Registration::PhoneClaims applies — is exactly how long that
      # is. The pending page asks the same module the same question when the
      # citizen types a different number there.
      def phone_in_verification?
        Decidim::Bih::Registration::PhoneClaims.claimed_elsewhere?(
          form.normalized_phone, organization:, except_user: @existing
        )
      end

      # Abandoned claims on this number, released inside the registration
      # transaction so a registration that rolls back leaves the old rows
      # alone. Why the number must come off them rather than be ignored, why
      # the ROW survives, and why a GRANTED row is never in scope, is
      # Registration::PhoneClaims' own contract.
      def release_abandoned_phone_claims!
        Decidim::Bih::Registration::PhoneClaims.release_stale!(
          form.normalized_phone, organization:, except_user: @existing
        )
      end

      def recover_pending_phone!
        matches = Registration::PhoneClaims.pending(form.normalized_phone, organization:).includes(:user).limit(2).to_a
        if matches.one? && Registration::PendingLifecycle.stub?(matches.first.user)
          @authorization = matches.first
          @user = @authorization.user
          @user.with_lock do
            @authorization.reload
            if recoverable_phone_claim?
              last_send = Registration::PhoneClaims.claimed_at(@authorization)
              budget = PhoneVerification::ResendBudget.new(organization_id: organization.id, authorization_id: @authorization.id,
                                                           challenge_version: @authorization.created_at.to_i, redis: RegistrationsController.attempt_limiter_redis)
              if last_send <= 60.seconds.ago
                spent = budget.spend!
                deliver_verification!(channels: ["sms"]) unless budget.store_error? || spent > PhoneVerification::ResendBudget::MAX_RESENDS
              end
            end
          end
        end
        # No pending access token, no changes to identity, and no account data
        # in the response. Only the link sent to the phone can open a session.
        broadcast(:recovery_sent)
      end

      def recoverable_phone_claim?
        Registration::PendingLifecycle.stub?(@user) && @authorization.granted_at.nil? &&
          SmsAuthorization.unique_id_candidates(form.normalized_phone).include?(@authorization.unique_id)
      end

      def refuse_phone_pending!
        form.errors.add(:mobile_phone_number, I18n.t("decidim.bih.registrations.errors.phone_pending"))
        broadcast(:invalid)
      end

      # Only reachable when the database refuses what the form accepted — a
      # race on the e-mail or nickname index, say. Every field-level message
      # would be a guess at that point, so the page gets a base error instead
      # of nothing to show.
      def refuse_unexpectedly!(error)
        Rails.logger.error("[registracija] account could not be created: #{failure_detail(error)}")
        form.errors.add(:base, I18n.t("decidim.bih.registrations.errors.failed")) if form.errors.empty?
        broadcast(:invalid)
      end

      # A uniqueness violation is the one error here whose MESSAGE names the
      # citizen: PostgreSQL reports the colliding values in its DETAIL line
      # ("Key (email, decidim_organization_id)=(mila@example.org, 1) already
      # exists"), and on the nickname index the name-derived handle instead.
      # It is exactly the race this rescue exists for, so it gets the class and
      # the index name and nothing else. Everything else keeps the sanitized
      # message, which is where the operational detail lives.
      def failure_detail(error)
        return Decidim::Bih::LogRedactor.constraint_violation(error) if error.is_a?(ActiveRecord::RecordNotUnique)

        "#{error.class}: #{Decidim::Bih::LogRedactor.error_message(error)}"
      end

      # The form lets every unaccepted invitation through; only this command
      # knows which of them may be claimed. One that may not — an invited
      # administrator, or an address taken between the form's check and here —
      # is refused with the same field error the form would have raised, so the
      # citizen sees a marked field rather than a bare "check the marked
      # fields" with nothing marked.
      def refuse_taken_email!
        form.errors.add(:email, I18n.t("decidim.bih.registrations.errors.email_taken"))
        broadcast(:invalid)
      end

      def persist_citizen!
        @user.assign_attributes(citizen_attributes)
        # The account is usable immediately: the e-mail address is unproven and
        # stays that way (Decidim::Bih::EmailConfirmation is what tracks proof;
        # confirmed_at means only "active" on a phone-first host).
        @user.skip_confirmation!

        if @user.persisted?
          # Accepting the invitation is what burns its token, so the mailed
          # link cannot later be used to take the account back.
          raise ActiveRecord::RecordInvalid, @user unless @user.accept_invitation!
        else
          @user.save!
        end
        if form.simplified?
          # Consent is collected with komsiluk after proof, never inferred
          # from an absent signup checkbox.
          TopicPreferences.set_all!(@user, enabled: false, source: "organization_default")
        else
          TopicPreferences.set_all!(@user, enabled: form.newsletter == true, source: "account")
        end
      end

      def citizen_attributes
        attributes = {
          name: form.name,
          email: form.email,
          organization:,
          locale: form.current_locale,
          tos_agreement: form.tos_agreement,
          accepted_tos_version: organization.tos_version,
          newsletter_notifications_at: form.simplified? ? nil : form.newsletter_at,
          password:,
          password_confirmation: password,
          password_updated_at: Time.current
        }
        # An adopted invitation already has a nickname, and re-deriving one
        # here would only produce a suffixed variant of it (nicknamize avoids
        # every taken nickname, including the row's own).
        attributes[:extended_data] = @user.extended_data.to_h.merge("mi_phone_only_registration" => true) if form.simplified?
        attributes[:nickname] = form.nickname if @user.nickname.blank?
        attributes
      end

      # The phone is the credential; nobody types this. Devise still needs an
      # encrypted_password on the row, and leaving it blank would make the
      # password sign-in path a live guessing target instead of a dead one.
      def password
        @password ||= SecureRandom.base58(40)
      end

      def assign_komsiluk!
        Decidim::Bih::CitizenProfile
          .for_user(@user, organization:)
          .assign_komsiluk!(form.komsiluk, source: "registration")
      end

      # The pending row, written inside the transaction and BEFORE anything is
      # sent. An account with no `sms` row is not `pending?`: the token this
      # command returns would resolve to nothing and the page that offers "send
      # it again" would refuse to open, leaving the citizen with an account and
      # no way back to it. Writing it up front means a provider that refuses,
      # or falls over, costs a message and nothing else.
      #
      # `unique_id` is the recipe Decidim itself would have written
      # (SmsAuthorization is the single source of it). The row keeps only that
      # HASH — never the number in clear — so the resend on the pending page
      # reads the number from the session or the live verify token, not from
      # here (Task 5b).
      def persist_pending_authorization!
        authorization = Decidim::Authorization.find_or_initialize_by(user: @user, name: "sms")
        authorization.unique_id = Decidim::Bih::SmsAuthorization.unique_id_for(form.normalized_phone)
        authorization.save!
        authorization
      end

      # Decidim's own SMS step, unchanged, now running against an already
      # committed authorization: PerformAuthorizationStep fills in the
      # verification metadata, and it is MobilePhoneForm's validation that
      # triggers the gateway (which mints the verify LoginToken and sends the
      # link). Returns false when the provider refused.
      #
      # `user` travels as a PARAM, not through with_context (R-D1):
      # MobilePhoneForm declares `user` as an ATTRIBUTE, and with_context sets
      # context, not attributes. Without it the gateway is handed no user, can
      # mint no user-bound link, and refuses to send at all.
      def deliver_verification!(channels: nil)
        phone_form = Decidim::Verifications::Sms::MobilePhoneForm
                     .from_params(mobile_phone_number: form.normalized_phone, delivery_channels: channels, user: @user)
                     .with_context(current_organization: organization)

        delivered = false
        Decidim::Verifications::PerformAuthorizationStep.call(@authorization, phone_form) do
          on(:ok) { delivered = true }
          on(:invalid) { delivered = false }
        end
        delivered
      rescue StandardError => e
        # The account is committed by now, so a provider that RAISES must not
        # take it down with it. The citizen lands on the pending page with
        # "the message did not go out, send it again" instead of nothing.
        Rails.logger.error(
          "[registracija] verification message not sent: #{e.class}: " \
          "#{Decidim::Bih::LogRedactor.error_message(e)}"
        )
        false
      end
    end
  end
end
