# frozen_string_literal: true

module Decidim
  module Bih
    module MailboxEncryptedFields
      extend ActiveSupport::Concern
      class_methods do
        def mailbox_encrypts(*fields)
          fields.each do |field|
            define_method(field) do
              value = public_send("#{field}_ciphertext")
              value.present? ? Infobip::EncryptedJobEnvelope.open(value, purpose: "report-mailbox", salt: "bih-report-mailbox-v1").fetch("value") : nil
            end
            define_method("#{field}=") do |value|
              public_send("#{field}_ciphertext=", value.nil? ? nil : Infobip::EncryptedJobEnvelope.seal({ value: }, purpose: "report-mailbox", salt: "bih-report-mailbox-v1"))
            end
            self.filter_attributes += [field, "#{field}_ciphertext"]
          end
        end
      end
    end
  end
end
