# frozen_string_literal: true

module Decidim
  module Bih
    module PhoneVerification
      # The one place a proven phone becomes a granted "sms" authorization plus
      # the two stored-number rows (SMS invitations, Viber notices). Used by
      # the magic link, the hidden code path, the Viber inbound path and by
      # citizens re-verifying an already granted number that has no rows yet.
      #
      # Idempotent: repeating it never double-grants or duplicates rows, and a
      # grant that is already present still (re)writes the phone rows. That
      # last part is the bug this class exists to fix — the previous
      # GrantsSmsAuthorization returned early on an already granted
      # authorization, so production ended up with granted "sms" rows and no
      # stored number at all (3 grants / 0 numbers on 2026-09-05). Anyone in
      # that state gets their rows written the next time they prove the phone.
      class Complete
        Result = Struct.new(:granted, :first_grant, :phone_recorded, :error, keyword_init: true) do
          def granted? = granted == true

          def first_grant? = first_grant == true

          def phone_recorded? = phone_recorded == true
        end

        def self.call(user:, phone:, session: nil)
          new(user:, phone:, session:).call
        end

        # Keep the public session keyword for existing browser/Viber callers.
        # Decidim 0.32 persists confirmation locks and counters on the
        # authorization; the upstream command no longer accepts a session.
        def initialize(user:, phone:, session: nil)
          @user = user
          @phone = Decidim::Bih::SmsAuthorization.normalize(phone)
          @session = session
        end

        def call
          return failure(:inactive_user) unless active_user?
          return failure(:phone_mismatch) if @phone.blank?

          # NEVER `return` (or `break`) out of the with_lock block: with_lock
          # opens a transaction and Rails 7 ROLLS IT BACK when the block is
          # left through a non-local exit, which would silently undo the grant
          # and the phone rows. The block therefore falls through to its own
          # value; the `return`s live one frame down, inside #complete_locked,
          # where they are ordinary method returns and the transaction commits.
          result = nil
          @user.with_lock { result = complete_locked }
          result
        end

        private

        def complete_locked
          authorization = Decidim::Authorization.find_by(user: @user, name: "sms")
          return failure(:no_authorization) if authorization.nil?

          # Phone-binding invariant: the pending (or granted) authorization must
          # belong to THIS phone. Decidim stores only the SHA-256, so the
          # comparison is hash-to-hash through the canonical recipe.
          expected_unique_id = Decidim::Bih::SmsAuthorization.unique_id_for(@phone)
          return failure(:phone_mismatch) unless authorization.unique_id == expected_unique_id

          first_grant = false
          unless authorization.granted?
            return failure(:confirmation_rejected) unless confirm!(authorization)

            first_grant = true
          end

          record_phone!
          void_live_verify_tokens!

          Result.new(
            granted: true,
            first_grant:,
            phone_recorded: Decidim::Bih::VerifiedPhone.consistent?(user: @user, organization: @user.organization),
            error: nil
          )
        end

        def active_user?
          @user.is_a?(Decidim::User) && @user.active_for_authentication? && !@user.blocked? && !@user.deleted?
        end

        # Replays the code already stored in the pending authorization's
        # verification_metadata through Decidim's canonical command, so the
        # grant stays 100% upstream machinery (broadcast, grant!, callbacks).
        #
        # The entrypoint must first validate the citizen's proof and enforce
        # AttemptLimiter. This replay completes that proven challenge; it is
        # not itself validation of a user-supplied code. Decidim 0.32 also
        # enforces persistent confirmation locks/expiry on the authorization.
        def confirm!(authorization)
          form = Decidim::Verifications::Sms::ConfirmationForm.from_params(
            verification_code: authorization.verification_metadata["verification_code"]
          )
          events = Decidim::Verifications::ConfirmUserAuthorization.call(authorization, form)
          # :already_confirmed is defensive and, from #complete_locked, dead:
          # that path only reaches here for a row it has just seen ungranted
          # while holding the user lock. It is kept because the cost of being
          # wrong about that is a citizen who proved their phone being told
          # they did not, and because upstream owns which event it broadcasts.
          events.has_key?(:ok) || events.has_key?(:already_confirmed)
        end

        def record_phone!
          Decidim::Bih::VerifiedPhone.synchronize!(user: @user, organization: @user.organization, phone: @phone)
        end

        # The phone is proven now, so every still-live "verify" link for this
        # citizen has done its job. Voiding them keeps a second delivered link
        # (SMS and Viber both carry one) from lingering as a usable credential.
        def void_live_verify_tokens!
          Decidim::Bih::LoginToken.invalidate_live!(user: @user, purpose: "verify")
        end

        def failure(error)
          Result.new(granted: false, first_grant: false, phone_recorded: false, error:)
        end
      end
    end
  end
end
