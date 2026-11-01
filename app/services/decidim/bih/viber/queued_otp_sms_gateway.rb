# frozen_string_literal: true

module Decidim
  module Bih
    module Viber
      # Backwards-compatible constant for hosts that instantiated the old
      # SMS-named adapter directly.
      class QueuedOtpSmsGateway < QueuedPhoneMessageGateway; end
    end
  end
end
