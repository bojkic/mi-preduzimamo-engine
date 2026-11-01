# frozen_string_literal: true
require "securerandom"
module Decidim
  module Bih
    module Goodwill
      module RequestIdentity
        UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
        module_function
        def key(kind, actor, value)
          raise ArgumentError, "valid request UUID required" unless value.is_a?(String) && UUID.match?(value)
          "request:#{kind}:#{actor.id}:#{value.downcase}"
        end
        def amount(value)
          raise ArgumentError, "integer amount required" unless value.to_s.match?(/\A[1-9]\d{0,8}\z/)
          Integer(value.to_s, 10)
        end
      end
    end
  end
end
