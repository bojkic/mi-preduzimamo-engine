# frozen_string_literal: true

require "minitest/autorun"
require "minitest/mock"
require "action_mailer"
require_relative "../../../../app/mailers/decidim/bih/mail_reply_to"

module Decidim
  module Bih
    class << self
      attr_accessor :mailer_reply_to unless method_defined?(:mailer_reply_to)
    end
  end
end

class MailReplyToCallbackTest < Minitest::Test
  # Exercise ActionMailer's actual after-action processing, including the
  # parameterized path used by previously queued MailDeliveryJob payloads.
  class NotificationMailer < ActionMailer::Base
    after_action :set_smtp

    def notify(recipient, reply_to: nil)
      return if recipient.blank?

      mail(to: recipient, from: "platform@example.org", reply_to:, subject: self.class.name, body: self.class.name)
    end

    private

    def set_smtp; end

    prepend Decidim::Bih::MailReplyTo::CoreSmtpDefaults
  end

  def test_blank_recipient_returns_null_mail_without_trying_to_render_a_template
    Decidim::Bih.stub(:mailer_reply_to, "support@example.org") do
      assert_instance_of ActionMailer::Base::NullMail, NotificationMailer.notify("").message
    end
  end

  def test_parameterized_queued_action_with_blank_recipient_also_remains_null
    Decidim::Bih.stub(:mailer_reply_to, "support@example.org") do
      assert_instance_of ActionMailer::Base::NullMail, NotificationMailer.with({}).notify("").message
    end
  end

  def test_real_recipient_keeps_body_and_gets_the_configured_reply_to
    Decidim::Bih.stub(:mailer_reply_to, "support@example.org") do
      message = NotificationMailer.notify("citizen@example.org").message
      assert_equal ["citizen@example.org"], message.to
      assert_equal ["support@example.org"], message.reply_to
      assert_equal NotificationMailer.name, message.body.decoded
    end
  end

  def test_explicit_reply_to_is_preserved
    Decidim::Bih.stub(:mailer_reply_to, "support@example.org") do
      message = NotificationMailer.notify("citizen@example.org", reply_to: "case@example.org").message
      assert_equal ["case@example.org"], message.reply_to
    end
  end
end
