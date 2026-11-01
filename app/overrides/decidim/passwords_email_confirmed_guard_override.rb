# frozen_string_literal: true

# An unproven e-mail address is not a recovery channel (spec 9.2). Phone-first
# accounts are created with confirmed_at set (skip_confirmation! at sign-up), so
# Devise would happily mail a reset link to whatever address was typed at
# sign-up — including a stranger's, or a typo that belongs to somebody else.
# Both ends of the reset flow are guarded here.
#
# The guard is scoped to hosts that actually run phone-first. On a stock host
# confirmed_at still means "clicked the e-mail link", and an account that never
# confirmed is a perfectly ordinary account that must keep receiving reset mail
# the way Decidim always sent it — so with the flag off BOTH actions return to
# core untouched, before EmailConfirmation is ever consulted. (EmailConfirmation
# answers false for confirmed_at IS NULL regardless of the flag, which is right
# for phone-first and wrong as a reason to refuse recovery on a host that never
# opted in.)
#
# The refusal in #create must be INDISTINGUISHABLE from an ordinary request, or
# the endpoint becomes an oracle for "which addresses have an account here".
# Rather than hand-picking a flash key, the branch runs Devise's own
# `successfully_sent?` + `respond_with({}, location: ...)` — the exact pair
# Devise::PasswordsController#create runs on the happy path — so the status,
# the Location header and the flash stay identical whatever `Devise.paranoid`
# is set to (Decidim ships it true, decidim-core config/initializers/devise.rb).
# Because that silence is invisible to the citizen, each refusal is logged at
# info level by user id only — never the address, which is exactly the datum
# the paranoid response exists to withhold.
module Decidim
  module Bih
    module PasswordsEmailConfirmedGuardOverride
      def create
        return super unless Decidim::Bih.phone_first_registration

        user = unproven_recipient
        if user || resource_params[:email].to_s.strip.blank?
          log_refused_reset(user) if user
          # Same two lines Devise runs when the mail really was sent; the only
          # difference is that no mail was sent and no token was written.
          self.resource = resource_class.new
          successfully_sent?(resource)
          return respond_with({}, location: after_sending_reset_password_instructions_path_for(resource_name))
        end

        super
      end

      def update
        return super unless Decidim::Bih.phone_first_registration

        token = resource_params[:reset_password_token].to_s
        user = resource_class.with_reset_password_token(token) if token.present?
        if user && !Decidim::Bih::EmailConfirmation.confirmed?(user)
          log_refused_reset(user)
          flash[:alert] = I18n.t("decidim.bih.passwords.unconfirmed_email") if is_flashing_format?
          return redirect_to(new_password_path(resource_name))
        end

        super
      end

      private

      # The account Devise would have mailed, but only when its current address
      # is unproven; nil otherwise (including "no such account", which must
      # keep falling through to Devise untouched).
      #
      # The lookup mirrors Devise's own: reset_password_keys on Decidim::User
      # are [:decidim_organization_id, :email] and the address is matched after
      # the strip/downcase Devise's parameter filter applies
      # (strip_whitespace_keys / case_insensitive_keys).
      def unproven_recipient
        address = resource_params[:email].to_s.strip.downcase
        return nil if address.blank?

        user = resource_class.find_by(email: address, organization: current_organization)
        return nil if user.blank? || Decidim::Bih::EmailConfirmation.confirmed?(user)

        user
      end

      # Id only. The address must never reach the log: the whole point of the
      # paranoid response is that this endpoint does not disclose addresses.
      def log_refused_reset(user)
        Rails.logger.info("[bih] password reset refused for unproven e-mail, user #{user.id}")
      end
    end
  end
end

Decidim::Devise::PasswordsController.prepend(Decidim::Bih::PasswordsEmailConfirmedGuardOverride)
