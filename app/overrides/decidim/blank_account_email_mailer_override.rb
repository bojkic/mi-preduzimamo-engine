# frozen_string_literal: true

module Decidim
  module Bih
    module BlankAccountEmailMailerOverride
      def mail(headers = {}, &)
        headers = headers.dup
        [:to, :cc, :bcc].each do |key|
          headers[key] = headers[key].compact_blank if headers[key].is_a?(Array)
        end
        if absent_account_email?(headers)
          # The outer process callback returns ActionMailer's NullMail without
          # rendering a layout, running SMTP callbacks or recording delivery.
          throw :bih_absent_email
        end

        super
      end

      private

      def absent_account_email?(headers)
        headers.has_key?(:to) && [:to, :cc, :bcc].all? { |key| Array(headers[key]).all?(&:blank?) }
      end

      def skip_absent_account_email
        catch(:bih_absent_email) { yield }
      end
    end
  end
end

unless ActionMailer::Base < Decidim::Bih::BlankAccountEmailMailerOverride
  ActiveSupport.on_load(:action_mailer) { prepend Decidim::Bih::BlankAccountEmailMailerOverride }
  ActionMailer::Base.prepend_around_action :skip_absent_account_email
end
