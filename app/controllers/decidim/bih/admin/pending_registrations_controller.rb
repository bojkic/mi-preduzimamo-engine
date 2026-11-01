# frozen_string_literal: true

module Decidim
  module Bih
    module Admin
      # "Ponovo pošalji potvrdu telefona" on the participants list: re-send the
      # verification (resume e-mail + SMS with a fresh link and code) to a
      # citizen whose one-step registration is still pending.
      #
      # Global admins only — the same people who may block a participant. The
      # command decides everything else (stub or not, number on record,
      # throttle) and every outcome comes back as a flash, never a 500.
      # Nothing here can grant a phone.
      class PendingRegistrationsController < Decidim::Bih::Admin::ApplicationController
        before_action :ensure_global_admin!

        # ONE POST. No preview, no confirmation step, no wizard: this is a
        # resend the citizen is waiting for, and the operator asked for it by
        # clicking it. What it gains here is only a fuller flash - what was
        # sent, on which channels, and what it cost.
        def resend
          user = Decidim::User.find_by(id: params[:user_id], organization: current_organization, deleted_at: nil)
          result = (Decidim::Bih::Registration::ResendVerification.call(user, actor: current_user, source: "admin") if user)
          status = result&.status || :not_found
          flash[status == :sent ? :notice : :alert] = resend_message(status, result)
          redirect_to decidim_admin.officializations_path
        end

        private

        def resend_message(status, result)
          base = t("decidim.bih.admin.pending_registrations.resend.#{status}")
          return [base, resend_cost(result)].compact.join(" ") if status == :sent
          return [base, retry_hint(result)].compact.join(" ") if status == :throttled

          base
        end

        # The scope and the cost of exactly one resend, stated rather than
        # implied: e-mail plus an SMS-only leg, one billable segment.
        def resend_cost(result)
          t("decidim.bih.admin.pending_registrations.resend.one_sms_segment",
            count: result&.sms_segments || Decidim::Bih::Registration::ResendVerification::SMS_SEGMENTS_PER_RESEND)
        end

        # Only when the throttle could actually say. A nil stays unsaid: a
        # made-up time would invite an immediate, refused retry.
        def retry_hint(result)
          return nil if result&.next_allowed_at.blank?

          t("decidim.bih.admin.pending_registrations.resend.retry_at",
            time: I18n.l(result.next_allowed_at, format: :short))
        end
      end
    end
  end
end
