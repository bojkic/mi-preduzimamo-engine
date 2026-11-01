# frozen_string_literal: true

require "digest"

module Decidim
  module Bih
    # Rate-limit keys that must not be readable.
    #
    # A Rack::Attack discriminator becomes a cache key and turns up in the
    # throttle store and its logs, so the value it is built from has to be one
    # that leaks nothing. Both the host's own Rack::Attack rules and the
    # initializer this engine generates call the methods here, so the two
    # count the same citizen under the same key.
    module Throttling
      # The key for a phone-number-keyed throttle, or nil when there is no
      # number to count.
      #
      # Normalised first, so spacing and punctuation cannot buy another paid
      # message, and SALTED with the application secret: a bare SHA-256 of a
      # phone number is one lookup table away from being the number itself
      # (the whole BiH mobile space is a few million candidates), while the
      # salted digest is useless to anyone who gets a look at the store. It is
      # stable for the life of the secret, which is all a 15-minute window
      # needs.
      def self.phone_key(raw)
        # Plain Ruby, no ActiveSupport: this file is also required directly by
        # the generator test, which boots no Rails.
        normalized = raw.to_s.gsub(/[^+0-9]/, "")
        return if normalized.empty?

        Digest::SHA256.hexdigest("#{normalized}-#{Rails.application.secret_key_base}")
      end
    end
  end
end
