# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      # Deterministic, model-free triage (plan §4.2). Provider labels decide what
      # we sent; bulk/list headers only suppress automatic responses.
      class Classifier
        AUTO_SUBJECT = /\A\s*(automatic reply|auto(matski|matic)? ?(odgovor|reply)|out of (the )?office|odsutan|odsutna|nisam u (kancelariji|uredu))\b/i
        SYSTEM_SENDERS = /\A(no-?reply@accounts\.google\.com|.+@(google|workspace-noreply\.google)\.com)\z/i

        def self.call(mail, labels:, own_message_ids:)
          bulk = %w(bulk junk list).include?(mail["Precedence"].to_s.strip.downcase) || mail["List-Id"].present?
          { classification: classification(mail, labels, own_message_ids), no_auto_response: bulk }
        end

        def self.classification(mail, labels, own_message_ids)
          return "draft" if labels.include?("\\Draft")
          return own_message_ids.include?(mail.message_id.to_s) ? "outbound_copy" : "staff_sent" if labels.include?("\\Sent")
          return "bounce" if bounce?(mail)
          return "system_notice" if Array(mail.from).any? { |address| address.to_s.match?(SYSTEM_SENDERS) }
          return "auto_reply" if auto_reply?(mail)

          "candidate"
        end

        def self.bounce?(mail)
          (mail.mime_type == "multipart/report" && mail.content_type.to_s.include?("delivery-status")) ||
            Array(mail.from).any? { |address| address.to_s.match?(/\A(mailer-daemon|postmaster)@/i) }
        end

        def self.auto_reply?(mail)
          submitted = mail["Auto-Submitted"].to_s.strip.downcase
          return true if submitted.present? && submitted != "no"
          return true if mail["X-Autoreply"].present? || mail["X-Autorespond"].present?

          mail.subject.to_s.match?(AUTO_SUBJECT)
        end
      end
    end
  end
end