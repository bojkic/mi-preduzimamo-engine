# frozen_string_literal: true

module Decidim
  module Bih
    # Thin controller/service-facing wrapper around
    # Decidim::Bih::PhoneVerification::Complete, which owns the whole
    # "proven phone → granted sms authorization + stored numbers" step.
    #
    # One path reaches it, proving phone possession through a one-time link
    # DELIVERED to the phone (never page-displayed):
    #
    #   ViberVerifyFlow#call — the user's Viber receives the link and the
    #                          inbound webhook fires.
    #
    # (MagicLinksController#consume used to come through here too. It now calls
    # PhoneVerification::Complete directly, because it has to inspect the
    # Result and refuse the sign-in on a failed grant, which a boolean adapter
    # cannot express.)
    #
    # Because the token was delivered to the number, activating it proves the
    # phone was in the sender's possession, so granting from here is equivalent
    # in security to the typed-code path.
    #
    # This module keeps only the boolean-returning adapter and the shared
    # active-user predicate (ViberVerifyFlow gates its linkage write on the
    # same predicate). Everything else — the phone-binding invariant, the
    # canonical confirmation, the stored-number rows and the token voiding —
    # lives in the service, so there is exactly one implementation of it.
    module GrantsSmsAuthorization
      # Grants the sms authorization for +user+ bound to +expected_phone+ and
      # records the proven number. Returns true when the authorization is
      # granted at the end of the call (whether this call granted it or an
      # earlier one did), false otherwise.
      #
      # +session+ may be nil (the Viber inbound path has no Rails session) and
      # is accepted only so this signature stays stable — the service never
      # reads it and never lets it reach Decidim's throttle. See
      # PhoneVerification::Complete#confirm! for why.
      #
      # +expected_phone+ is REQUIRED in practice: without it there is nothing
      # to bind the grant to and nothing to store, so a blank value is refused
      # rather than granting an unbound authorization.
      #
      # Durable webhook callers pass +raise_on_failure: true+ so their
      # encompassing receipt transaction can roll back and retry instead of
      # consuming a token without its grant.
      def grant_sms_authorization(user, session = nil, expected_phone: nil, raise_on_failure: false)
        return false if expected_phone.blank?

        result = Decidim::Bih::PhoneVerification::Complete.call(user:, phone: expected_phone, session:)
        # A refusal is an expected outcome, not a crash — but a silent `false`
        # is unsupportable in production. Log the reason at info with the user
        # id and NOTHING else: never the phone, never the token, never the
        # authorization's unique_id (which is a hash of the number).
        Rails.logger.info("[GrantsSmsAuthorization] refused for user #{user&.id}: #{result.error}") if result.error
        raise "SMS authorization completion failed: #{result.error}" if raise_on_failure && !result.granted?

        result.granted?
      rescue StandardError => e
        Rails.logger.error(
          "[GrantsSmsAuthorization] failed for user #{user&.id}: " \
          "#{Decidim::Bih::LogRedactor.error_message(e)}"
        )
        raise if raise_on_failure

        false
      end

      private

      # True only when the user exists and is active, not blocked, not deleted.
      # Kept here (and duplicated inside the service, which cannot depend on a
      # controller concern) because ViberVerifyFlow calls it directly to gate
      # its Linkage write on the same predicate as the grant.
      def active_grantable_user?(user)
        user&.active_for_authentication? && !user.blocked? && !user.deleted?
      end
    end
  end
end
