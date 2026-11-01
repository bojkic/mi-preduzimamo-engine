# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module FileNumbers
        def self.scan(text) = text.to_s.scan(/(?<![\d])\d{2,3}[-–]\d{2,4}[-–]\d{1,6}\/\d{2,4}(?!\d)/).uniq
      end
    end
  end
end
