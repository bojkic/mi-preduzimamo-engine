# frozen_string_literal: true

# Override for Decidim::Verifications::PostalLetter::Admin::PostagesController.
#
# PROBLEM: The original core controller redirects to the pending-authorizations
# index on success. The engine's prior index view called
# PostalTokenService.issue_for_authorization on every render (GET), which
# minted a new LoginToken and invalidated all prior unconsumed postal tokens
# for that user — so viewing the list a second time burned the token already
# printed on a mailed letter.
#
# FIX: Tokens are now minted ONLY here, on the explicit "send letter" POST.
# After PerformAuthorizationStep succeeds, we mint one postal LoginToken for the
# authorization's user and render a printable letter view containing the
# recipient address, the 6-digit code, the confirm URL, and the QR SVG.
#
# Lifecycle contract:
#   - Each POST mints exactly one fresh token (re-sending deliberately issues a
#     new token for the new letter, per LoginToken.issue! semantics).
#   - The raw token is shown only in this POST response (never persisted in
#     plaintext, never logged).
#   - The index view is now read-only: listing the queue never touches tokens.
#
# LAYOUT: the letter renders in its own standalone layout, NOT
# "decidim/admin/users". Under the admin layout every printed letter carried the
# admin chrome — nav, the organisation switcher, the signed-in operator's e-mail
# — onto paper addressed to a citizen, and the layout's wrapper margins shifted
# the sheet so the address block could not line up with an envelope window.
module Decidim
  module Bih
    module Postal
      module PostalPostagesControllerOverride
        # After PerformAuthorizationStep succeeds, mint a postal token and render
        # the printable letter instead of redirecting to the index.
        def create
          enforce_permission_to :update, :authorization, authorization: @pending_authorization

          @form = ::Decidim::Verifications::PostalLetter::PostageForm.from_model(@pending_authorization)

          # Capture in a local so the Wisper/instance_eval block can reference it.
          # Decidim::Command#evaluate runs the block via instance_eval on the command
          # object — instance variables like @pending_authorization are NOT accessible
          # in that context. Local variables ARE captured by the closure.
          pending_authorization = @pending_authorization
          org_host = current_organization.host

          # postal_data is populated in the on(:ok) block and read by the render call
          # below. We use a local variable because the block runs via instance_eval
          # on the command object (not the controller), so instance variables set
          # in the block are on the command, not on self.
          postal_data = nil
          ok = false

          ::Decidim::Verifications::PerformAuthorizationStep.call(@pending_authorization, @form) do
            on(:ok) do
              ok = true
              postal_data = ::Decidim::Bih::Postal::PostalTokenService.issue_for_authorization(
                pending_authorization,
                host: org_host
              )
            end
          end

          if ok
            @postal_data = postal_data
            # Wrap in the presenter so the view can use .verification_address,
            # .verification_code, .letter_sent_at etc. (defined on AuthorizationPresenter).
            @pending_authorization = ::Decidim::Verifications::PostalLetter::AuthorizationPresenter.new(
              @pending_authorization
            )
            render "decidim/bih/postal_letter/admin/postages/printable_letter",
                   layout: "decidim/bih/postal_letter"
          else
            render json: {
              error: I18n.t("postages.create.error",
                            scope: "decidim.verifications.postal_letter.admin")
            }, status: :unprocessable_entity
          end
        end

        def resend
          enforce_permission_to :update, :authorization, authorization: @pending_authorization

          @postal_data = ::Decidim::Bih::Postal::OperatorAction.regenerate_and_issue!(
            @pending_authorization,
            host: current_organization.host
          )
          @pending_authorization = ::Decidim::Verifications::PostalLetter::AuthorizationPresenter.new(
            @pending_authorization
          )
          render "decidim/bih/postal_letter/admin/postages/printable_letter",
                 layout: "decidim/bih/postal_letter"
        rescue StandardError => e
          Rails.logger.error("[postal] resend failed: #{e.class}: #{e.message}")
          flash[:alert] = I18n.t("postages.resend.error",
                                 scope: "decidim.verifications.postal_letter.admin")
          redirect_to pending_authorizations_path
        end

        def cancel
          enforce_permission_to :update, :authorization, authorization: @pending_authorization

          ::Decidim::Bih::Postal::OperatorAction.cancel!(@pending_authorization)
          flash[:notice] = I18n.t("postages.cancel.success",
                                  scope: "decidim.verifications.postal_letter.admin")
          redirect_to pending_authorizations_path
        rescue StandardError => e
          Rails.logger.error("[postal] cancel failed: #{e.class}: #{e.message}")
          flash[:alert] = I18n.t("postages.cancel.error",
                                 scope: "decidim.verifications.postal_letter.admin")
          redirect_to pending_authorizations_path
        end
      end
    end
  end
end

Decidim::Verifications::PostalLetter::Admin::PostagesController.prepend(
  Decidim::Bih::Postal::PostalPostagesControllerOverride
)
