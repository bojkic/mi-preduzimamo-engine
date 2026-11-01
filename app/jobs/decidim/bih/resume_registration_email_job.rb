# frozen_string_literal: true

module Decidim
  module Bih
    # "Još jedan korak" — the single reminder a citizen who never answered the
    # verification message gets, fifteen minutes after signing up
    # (RegisterWithPhone schedules it).
    #
    # The link it carries holds the E-MAIL pending token: it can reopen the
    # pending page, where the message can be re-sent or the number corrected,
    # and it can never hand a session over, because the address it was sent to
    # is unproven. So this reminder verifies nothing at all — not the phone,
    # not the address. That is the whole point of the e-mail token variant.
    #
    # PRIVACY: the job's arguments are two ids and argument logging is off, so
    # neither the address nor the token can reach a log through the queue.
    #
    # There is no Decidim::Bih::ApplicationJob — an engine has no application
    # job to subclass — so ActiveJob::Base is the base every job in this engine
    # uses, the same way its mailers subclass ActionMailer::Base.
    class ResumeRegistrationEmailJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
      # Sent-once marker, on the user's extended_data. A timestamp rather than
      # a flag so operators can see WHEN the one reminder went out.
      SENT_AT_KEY = "mi_resume_email_sent_at"

      self.log_arguments = false

      queue_as :mailers

      discard_on ActiveJob::DeserializationError

      def perform(user_id, organization_id)
        user = Decidim::User.find_by(id: user_id, decidim_organization_id: organization_id)
        return if user.nil? || user.email.blank? || user.deleted? || user.blocked?
        # Verified in the meantime, or never had a phone step to finish:
        # either way there is nothing left to resume.
        return unless Decidim::Bih::Registration::PendingAccess.pending?(user)
        return if user.extended_data.to_h[SENT_AT_KEY].present?

        token = Decidim::Bih::Registration::PendingAccess.mint_email(user)
        Decidim::Bih::RegistrationMailer.resume(user, token).deliver_now
        mark_sent!(user)
      end

      private

      # update_column, not update!: this is a delivery receipt about a row this
      # job did not otherwise touch, and a user record that would not validate
      # today must not turn "the one reminder was sent" into "send it again".
      def mark_sent!(user)
        user.update_column( # rubocop:disable Rails/SkipsModelValidations
          :extended_data,
          user.extended_data.to_h.merge(SENT_AT_KEY => Time.current.utc.iso8601)
        )
      end
    end
  end
end
