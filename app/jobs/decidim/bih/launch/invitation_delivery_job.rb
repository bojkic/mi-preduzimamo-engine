# frozen_string_literal: true

module Decidim
  module Bih
    module Launch
      # ActionMailer::MailDeliveryJob (the default `deliver_later` job) logs
      # its arguments, because ActiveJob::Logging#log_arguments defaults to
      # true and neither ActionMailer::MailDeliveryJob nor InvitationMailer
      # overrides it. InvitationMailer's arguments include the fully
      # rendered campaign message body, which for P1 interpolates the
      # citizen's venue entry code and a 72-hour bearer-token confirmation
      # link — both of which land in the production log (info level) via
      # ActiveJob's enqueue/perform log lines.
      #
      # Spec §10: "Kod pozivnice i broj telefona nikad u logove." Every
      # Infobip job (SendSmsJob, SendViberTextJob, SendPhoneMessageJob, ...)
      # already disables argument logging; this gives InvitationMailer's
      # delivery job the same treatment, assigned via
      # InvitationMailer.delivery_job.
      class InvitationDeliveryJob < ActionMailer::MailDeliveryJob
        self.log_arguments = false
      end
    end
  end
end
