# frozen_string_literal: true

module Decidim
  module Bih
    # Sidekiq logs the serialized job on failure even when ActiveJob argument
    # logging is disabled. Redact the ERROR CONTEXT, not the executable payload.
    module MailJobLogPrivacy
      module_function

      def call(_exception, context, _config)
        job = context[:job] || context["job"]
        return unless mail_job?(job)

        key = context.has_key?(:job) ? :job : "job"
        context[key] = job.merge("args" => "[FILTERED]")
        [:jobstr, "jobstr"].each { |name| context[name] = "[FILTERED]" if context.has_key?(name) }
      end

      def mail_job?(job)
        return false unless job.is_a?(Hash)
        return true if job["wrapped"] == "ActionMailer::MailDeliveryJob"

        payload = Array(job["args"]).first
        arguments = payload.is_a?(Hash) ? payload["arguments"] : nil
        arguments.is_a?(Array) && arguments[0].is_a?(String) &&
          %w(deliver_now deliver_now!).include?(arguments[2])
      end
    end
  end
end
