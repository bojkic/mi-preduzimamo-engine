# frozen_string_literal: true

require "test_helper"

module Decidim
  module Bih
    module RailsHarness
      # FINDING 1 (2026-08-31 final review, merge-blocking): ActionMailer's
      # default delivery job (ActionMailer::MailDeliveryJob) logs its
      # arguments, and InvitationMailer's arguments include the fully
      # rendered campaign message body — for P1 that interpolates the
      # citizen's venue entry code and a 72-hour bearer-token confirmation
      # link. Spec §10 requires neither ever reach the log. This asserts the
      # mailer uses a dedicated delivery job with argument logging off,
      # mirroring every Infobip job in this engine.
      class InvitationMailerTest < ActiveSupport::TestCase
        include ActiveJob::TestHelper

        setup do
          @organization = create_organization
          @user = FactoryBot.create(:user, :confirmed, organization: @organization)
        end

        test "uses a dedicated delivery job, not the default, with argument logging disabled" do
          refute_equal ActionMailer::MailDeliveryJob, Decidim::Bih::Launch::InvitationMailer.delivery_job
          assert_equal Decidim::Bih::Launch::InvitationDeliveryJob, Decidim::Bih::Launch::InvitationMailer.delivery_job
          refute Decidim::Bih::Launch::InvitationMailer.delivery_job.log_arguments
        end

        test "a campaign message enqueues that dedicated delivery job" do
          assert_enqueued_with(job: Decidim::Bih::Launch::InvitationDeliveryJob) do
            Decidim::Bih::Launch::InvitationMailer
              .with(user: @user, body: "MI-4821 https://mi.fondacijabijeljina.com/v/AbCdEfGhIjKlMnOp", message_key: "p1", locale: :sr)
              .campaign_message
              .deliver_later
          end
        end
      end
    end
  end
end
