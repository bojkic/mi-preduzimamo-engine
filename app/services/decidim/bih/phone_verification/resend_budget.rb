# frozen_string_literal: true

module Decidim
  module Bih
    module PhoneVerification
      # A cap on how many messages one verification challenge may ever send.
      #
      # The 60-second resend cooldown lives on the authorization row and caps
      # the RATE; it caps no total. Rotating sessions against the same live
      # token turns "one a minute" into roughly fifteen paid messages in a
      # quarter of an hour, aimed at whatever number the citizen typed — which
      # need not be their own. This counter is the total, and it is the reason
      # the two budgets are separate: burning the wrong-code attempts must not
      # also stop someone from asking for another message, and a resend must
      # not buy a fresh set of guesses.
      #
      # Same (organization, authorization, challenge) key material and the
      # same fail-closed behaviour as AttemptLimiter — only the key namespace
      # and the numbers differ. Fail-closed is the money direction here: a
      # refused resend during a Redis blip costs the citizen a minute, an
      # uncounted one costs the foundation messages.
      class ResendBudget < AttemptLimiter
        MAX_RESENDS = 5
        TTL_SECONDS = 900
        KEY_PREFIX = "decidim-bih:phone-verification:resends:"

        # The inherited counter, under the name this class means by it: an
        # accepted resend is not a failure, it is a message paid for.
        alias spend! record_failure!

        private

        def key_prefix = KEY_PREFIX

        def limit = MAX_RESENDS

        def ttl_seconds = TTL_SECONDS
      end
    end
  end
end
