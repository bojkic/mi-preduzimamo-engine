# frozen_string_literal: true

module Decidim
  module Bih
    module Registration
      # One operator re-send per citizen per ten minutes, separate from the
      # citizen's own five-resend budget (PhoneVerification::ResendBudget).
      # Same atomic Redis counter as the wrong-code limiter; Redis trouble
      # reads as throttled (fail closed) — the operator retries in a minute,
      # nobody is billed twice by a flapping store.
      class OperatorResendThrottle < Decidim::Bih::PhoneVerification::AttemptLimiter
        MAX_SENDS = 1
        TTL_SECONDS = 600
        KEY_PREFIX = "decidim-bih:registration:operator-resend:"

        alias spend! record_failure!

        private

        def key_prefix = KEY_PREFIX

        def limit = MAX_SENDS

        def ttl_seconds = TTL_SECONDS
      end
    end
  end
end
