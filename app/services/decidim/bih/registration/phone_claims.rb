# frozen_string_literal: true

module Decidim
  module Bih
    module Registration
      # Who, other than this citizen, is currently claiming a phone number.
      #
      # A PENDING `sms` Decidim::Authorization is a claim on a number: while it
      # stands, Decidim's own AuthorizationHandler#duplicate refuses to verify
      # that number for anybody else. A claim is only meaningful while the code
      # it was staked with could still be answered — VERIFY_TTL, 24 hours —
      # and after that it is abandonment, not somebody mid-flow.
      #
      # Two callers need exactly the same bound and must not each invent one:
      # RegisterWithPhone refuses a LIVE claim ("try again in 24 hours") and
      # releases every stale one inside its transaction, and the pending page
      # refuses a live claim when the citizen types a different number. A
      # difference between the two would show up as a number that the form
      # accepts and the page rejects, or the reverse.
      #
      # GRANTED rows are never in scope here. A proven number is
      # SmsAuthorization.taken?'s business, and nothing in this module may
      # touch proof.
      module PhoneClaims
        module_function

        # Whether this pending claim can still be answered.
        def live?(authorization)
          claimed_at(authorization) > Decidim::Bih::LoginToken::VERIFY_TTL.ago
        end

        # An abandoned claim: staked long enough ago that the code it was
        # staked with is dead.
        def stale?(authorization) = !live?(authorization)

        # Is somebody ELSE in the middle of verifying this number, right now?
        def claimed_elsewhere?(phone, organization:, except_user: nil)
          pending(phone, organization:, except_user:).any? { |authorization| live?(authorization) }
        end

        # Take this number off every abandoned claim on it. The number has to
        # GO rather than merely be ignored: Decidim refuses to verify a number
        # any other authorization row holds, so leaving one strands the next
        # citizen at the SMS step with no way out.
        #
        # The ROW stays. It is somebody's only `sms` authorization, and
        # destroying it destroys their registration with it: PendingAccess
        # .pending? goes false, so every pending route refuses their token, the
        # resume e-mail dead-ends on the registration form, and the address
        # they registered with is taken by an account they can no longer reach.
        # That citizen is the one who mistyped a number — exactly who the
        # resume e-mail exists to rescue. Releasing keeps all of it: the row
        # still answers "pending", so the page opens and offers a new number
        # (session variant) or start over (e-mail variant), while
        # AuthorizationHandler#duplicate no longer matches and
        # PhoneVerification::Complete fails closed on the mismatch.
        #
        # Through the model, never update_columns: `verification_metadata` is
        # an encrypted attribute (Decidim::Authorization's encrypt_attribute),
        # and a raw column write would put cleartext in it. Call it inside the
        # caller's own transaction, so work that rolls back leaves the old rows
        # alone. Only the row id is logged — never the number, never its owner.
        #
        # Returns the number of claims released.
        def release_stale!(phone, organization:, except_user: nil)
          pending(phone, organization:, except_user:).count do |authorization|
            next false unless stale?(authorization)

            authorization.update!(unique_id: nil, verification_metadata: {})
            Rails.logger.info("[decidim-bih] released stale pending sms authorization #{authorization.id}")
            true
          end
        end

        # Every PENDING `sms` row in this organization that belongs to somebody
        # other than +except_user+ and matches any shape this number could have
        # been stored under — delivery A's flow keys rows on the number AS
        # TYPED, which is what SmsAuthorization.unique_id_candidates exists for.
        def pending(phone, organization:, except_user: nil)
          unique_ids = Decidim::Bih::SmsAuthorization.unique_id_candidates(phone)
          return Decidim::Authorization.none if unique_ids.empty?

          scope = Decidim::Authorization
                  .joins(:user)
                  .where(decidim_users: { decidim_organization_id: organization.id })
                  .where(name: "sms", unique_id: unique_ids, granted_at: nil)
          except_user ? scope.where.not(decidim_user_id: except_user.id) : scope
        end

        # When the claim was staked. `verification_metadata` is an encrypted
        # column, so this cannot be a WHERE clause — but the set is one phone
        # number's worth of rows, so reading them is cheap. `code_sent_at` is
        # when the message actually went out; `created_at` covers a row written
        # before any send, which is exactly the shape RegisterWithPhone writes.
        def claimed_at(authorization)
          sent_at = authorization.verification_metadata.to_h["code_sent_at"]
          parsed = begin
            sent_at.present? ? Time.zone.parse(sent_at.to_s) : nil
          rescue ArgumentError
            nil
          end
          parsed || authorization.created_at
        end
      end
    end
  end
end
