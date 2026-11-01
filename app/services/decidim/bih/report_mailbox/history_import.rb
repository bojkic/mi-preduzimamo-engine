# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module HistoryImport
        class AlreadyEffectful < StandardError; end
        module_function

        # The same row lock as processing makes this decision authoritative.
        # Earlier business effects cannot be undone by changing a history flag.
        def mark!(email)
          email.with_lock do
            return email if email.history_only
            if InboundEmailEffect.where(inbound_email: email).where.not(effect: "history_linked").exists?
              raise AlreadyEffectful, "Mail already produced case effects"
            end
            email.update!(history_only: true, history_reason: "forwarded_import", state: "history", locked_at: nil)
          end
          email
        end
      end
    end
  end
end
