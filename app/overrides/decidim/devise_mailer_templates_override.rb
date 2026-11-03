# frozen_string_literal: true

# Explicit fallback for namespaced mailer lookup during a fresh worker boot.
# Keep custom templates first; do not depend on inherited ActionView prefixes.
module Decidim
  module Bih
    module DeviseMailerTemplatesOverride
      protected

      def template_paths
        (super + ["devise/mailer"]).uniq
      end
    end
  end
end

mailer = Decidim::DecidimDeviseMailer
mailer.prepend(Decidim::Bih::DeviseMailerTemplatesOverride) unless mailer < Decidim::Bih::DeviseMailerTemplatesOverride
