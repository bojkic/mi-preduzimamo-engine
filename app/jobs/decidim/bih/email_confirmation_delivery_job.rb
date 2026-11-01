# frozen_string_literal: true

module Decidim
  module Bih
    # ActionMailer::MailDeliveryJob (the default `deliver_later` job) logs its
    # arguments, because ActiveJob::Logging#log_arguments defaults to true.
    # EmailConfirmationMailer#confirm takes a bearer token as its second
    # argument, so the default job would write that token to the production log
    # on both the enqueue and the perform line.
    #
    # Same treatment as Decidim::Bih::Launch::InvitationDeliveryJob, assigned
    # via EmailConfirmationMailer.delivery_job.
    class EmailConfirmationDeliveryJob < ActionMailer::MailDeliveryJob
      self.log_arguments = false
    end
  end
end
