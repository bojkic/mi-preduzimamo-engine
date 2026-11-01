# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module Decidim
  module Bih
    # One clock rule shared by public rendering and the locked signup write.
    class VolunteerSignupWindow
      def self.open?(deadline:, cancelled:, paused: false, at: Time.current)
        !cancelled && !paused && (deadline.blank? || deadline > at)
      end
    end
  end
end
