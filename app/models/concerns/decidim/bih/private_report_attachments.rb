# frozen_string_literal: true

module Decidim
  module Bih
    module PrivateReportAttachments
      extend ActiveSupport::Concern
      included do
        validate :private_attachment_services
      end

      private

      def private_attachment_services
        names = is_a?(InboundEmail) ? %w(attachments) : %w(photo files)
        names.each do |name|
          attached = public_send(name)
          entries = self.class.reflect_on_attachment(name).macro == :has_one_attached ? [attached.attachment].compact : attached.attachments
          entries.each do |attachment|
            errors.add(name, "requires encrypted private storage") unless ReportPrivateStorage.private?(attachment.blob)
          end
        end
      end
    end
  end
end
