# frozen_string_literal: true

require "securerandom"

module Decidim
  module Bih
    module Postal
      # Operator-only actions for pending postal-letter authorizations.
      #
      # Citizen flows stay request/confirm only; cancel/regenerate are exposed
      # only through the Decidim admin postal queue.
      module OperatorAction
        class << self
          def regenerate_and_issue!(authorization, host:)
            raise ArgumentError, "postal authorization already granted" if authorization.granted_at.present?

            authorization.update!(
              verification_metadata: regenerated_metadata(authorization)
            )
            PostalTokenService.issue_for_authorization(authorization, host:)
          end

          def cancel!(authorization)
            raise ArgumentError, "postal authorization already granted" if authorization.granted_at.present?

            invalidate_postal_tokens!(authorization.user)
            authorization.destroy!
          end

          private

          def regenerated_metadata(authorization)
            metadata = authorization.verification_metadata.to_h
            {
              "address" => metadata.fetch("address"),
              "verification_code" => verification_code,
              "letter_sent_at" => Time.current
            }
          end

          def verification_code
            SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
          end

          def invalidate_postal_tokens!(user)
            # rubocop:disable Rails/SkipsModelValidations
            LoginToken.where(user:, purpose: "postal", consumed_at: nil).update_all(consumed_at: Time.current)
            # rubocop:enable Rails/SkipsModelValidations
          end
        end
      end
    end
  end
end
