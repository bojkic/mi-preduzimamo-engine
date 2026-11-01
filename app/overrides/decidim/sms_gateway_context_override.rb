# frozen_string_literal: true

# Decidim's MobilePhoneForm passes only the organization to the SMS gateway.
# The magic-link flow needs the user too (to mint a user-bound LoginToken), so
# widen the context — purely additive, upstream callers ignore extra keys.
#
# The gateway also needs to know which delivery channels the caller allows:
# the phone-first flow lets a citizen ask for a plain SMS when the Viber
# message never arrives, and that choice has to reach
# Decidim::Bih::Infobip::Client#send_phone_message.
module Decidim
  module Bih
    module SmsGatewayContextOverride
      private

      def sms_gateway_context
        super.merge(user:, channels: try(:delivery_channels))
      end
    end
  end
end

Decidim::Verifications::Sms::MobilePhoneForm.prepend(Decidim::Bih::SmsGatewayContextOverride)

# The channel choice arrives as a form parameter, so it has to be a declared
# attribute — AttributeObject drops anything it does not know about. It
# defaults to an empty list, and Infobip::Client#normalize_phone_channel_subset
# reads nil and [] alike as "no restriction", i.e. the full configured channel
# order; anything else must be a strict, correctly ordered subset of
# PHONE_CHANNEL_ORDER or the send is refused.
#
# The element type is pinned to String rather than left as a bare Array: this
# is unfiltered request data, and normalize_phone_channel_subset coerces every
# element with #to_s.strip.downcase.to_sym and then refuses anything that is
# not a known channel with a controlled Infobip::Error. Declaring [String]
# keeps that refusal in charge: a bare Array would hand it whatever the
# request nested inside the parameter — a Hash, say — whose #to_s is a
# stringified hash, i.e. a confusing error instead of a clear one.
Decidim::Verifications::Sms::MobilePhoneForm.class_eval do
  attribute :delivery_channels, [String]
end
