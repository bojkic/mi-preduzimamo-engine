# frozen_string_literal: true

module Decidim
  module Bih
    # Shared logic for granting a named pending authorization via the canonical
    # Decidim::Verifications::ConfirmUserAuthorization command.
    #
    # This is the GENERALIZED successor to GrantsSmsAuthorization:
    #   - GrantsSmsAuthorization (kept unchanged) handles the "sms" auth with
    #     phone-binding.
    #   - This concern adds #grant_named_authorization for any named pending
    #     authorization where the proof is delivery-to-the-recipient rather than
    #     phone possession (e.g. postal_letter: delivery to a physical address).
    #
    # For postal_letter the token's single-use + physical delivery IS the proof;
    # there is no phone to bind. The same active/!blocked/!deleted guard applies.
    #
    # Never raises — a failure to grant must not break sign-in.
    module GrantsAuthorization
      # Grant the pending authorization named +auth_name+ for +user+.
      #
      # +session+ may be nil (non-browser paths). +ConfirmUserAuthorization+ uses
      # the session only for attempt-throttle state; nil is substituted with {}
      # so the throttle tracking works without raising NoMethodError.
      #
      # Returns true on a successful grant, false on any guard failure or error.
      def grant_named_authorization(user, auth_name, session = nil)
        return false unless active_grantable_user?(user)

        authorization = Decidim::Authorization.find_by(user:, name: auth_name)
        return false if authorization.blank? || authorization.granted?

        confirm_named_authorization(authorization, session)
      rescue StandardError => e
        Rails.logger.error(
          "[GrantsAuthorization] failed for user #{user.id} / #{auth_name}: " \
          "#{Decidim::Bih::LogRedactor.error_message(e)}"
        )
        false
      end

      private

      # True only when the user exists and is active, not blocked, not deleted.
      def active_grantable_user?(user)
        user&.active_for_authentication? && !user.blocked? && !user.deleted?
      end

      def confirm_named_authorization(authorization, session)
        # Replay the verification code already stored in the pending
        # authorization's verification_metadata through the canonical command
        # so all upstream callbacks (grant!, broadcasts, after_commit hooks) fire.
        #
        # The postal_letter workflow stores the code under different keys
        # depending on whether the letter has been marked as sent:
        #
        #   Before admin marks as sent (AddressForm state):
        #     { "address" => ..., "pending_verification_code" => "123456" }
        #
        #   After admin marks as sent (PostageForm state):
        #     { "address" => ..., "verification_code" => "123456", "letter_sent_at" => ... }
        #
        # ConfirmUserAuthorization#confirmation_successful? iterates the form's
        # verification_metadata and checks each key against the auth's metadata —
        # so the form MUST use the same key name that is present in the auth's
        # metadata. We detect which key is present and build the form accordingly.
        meta = authorization.verification_metadata
        code_key, code_value = if meta.has_key?("verification_code")
                                 ["verification_code", meta["verification_code"]]
                               elsif meta.has_key?("pending_verification_code")
                                 ["pending_verification_code", meta["pending_verification_code"]]
                               end
        return false if code_value.blank?

        # Build a minimal form that matches ConfirmUserAuthorization's contract.
        form = PostalConfirmationForm.new(code_key: code_key, code_value: code_value)
        effective_session = session || {}
        granted = false
        Decidim::Verifications::ConfirmUserAuthorization.call(authorization, form, effective_session) do
          on(:ok) { granted = true }
          on(:invalid) { granted = false }
        end
        granted
      end

      # Minimal inline form that carries the verification code metadata under
      # whichever key is present in the authorization's verification_metadata
      # (either "verification_code" or "pending_verification_code").
      #
      # ConfirmUserAuthorization#confirmation_successful? iterates
      # form.verification_metadata keys and checks them against the stored
      # authorization metadata — so the key must match.
      class PostalConfirmationForm
        include ActiveModel::Model

        attr_accessor :code_key, :code_value

        def verification_metadata
          { code_key => code_value }
        end

        def valid?
          code_key.present? && code_value.present?
        end

        def invalid?
          !valid?
        end
      end
    end
  end
end
