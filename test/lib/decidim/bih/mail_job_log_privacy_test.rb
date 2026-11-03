# frozen_string_literal: true

require "minitest/autorun"
require "sidekiq"
require "sidekiq/config"
require "stringio"
require "json"
require_relative "../../../../lib/decidim/bih/mail_job_log_privacy"

class MailJobLogPrivacyTest < Minitest::Test
  def job(mailer = "Decidim::DecidimDeviseMailer", wrapped = "ActionMailer::MailDeliveryJob")
    { "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper", "wrapped" => wrapped,
      "jid" => "synthetic",
      "args" => [{ "arguments" => [mailer, "confirmation_instructions", "deliver_now", { "args" => ["private@example.invalid", "synthetic-secret-token"] }] }] }
  end

  def log_failure(payload)
    output = StringIO.new
    config = Sidekiq::Config.new
    config.logger = Logger.new(output)
    config.error_handlers.unshift(Decidim::Bih::MailJobLogPrivacy)
    config.handle_exception(RuntimeError.new("Synthetic delivery failure"), { job: payload, jobstr: JSON.generate(payload) })
    output.string
  end

  def test_actual_sidekiq_error_logger_redacts_legacy_and_custom_mail_jobs_without_changing_the_job
    [job, job("Decidim::Bih::EmailConfirmationMailer", "Decidim::Bih::EmailConfirmationDeliveryJob")].each do |payload|
      original = JSON.generate(payload)
      output = log_failure(payload)
      refute_includes output, "synthetic-secret-token"
      refute_includes output, "private@example.invalid"
      assert_includes output, "[FILTERED]"
      assert_includes output, "Synthetic delivery failure"
      assert_equal original, JSON.generate(payload), "execution/retry payload must stay intact"
    end
  end

  def test_other_jobs_keep_their_existing_diagnostics
    payload = { "class" => "SyntheticCountJob", "args" => [123] }
    context = { job: payload, jobstr: "original" }
    Decidim::Bih::MailJobLogPrivacy.call(RuntimeError.new, context, nil)
    assert_same payload, context[:job]
    assert_equal "original", context[:jobstr]
  end

  def test_unrecognized_context_is_left_unchanged
    [{}, { job: nil }, { job: [] }].each do |context|
      before = context.dup
      Decidim::Bih::MailJobLogPrivacy.call(RuntimeError.new, context, nil)
      assert_equal before, context
    end
  end
end
