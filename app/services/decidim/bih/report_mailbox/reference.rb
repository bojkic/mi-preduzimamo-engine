# frozen_string_literal: true

module Decidim
  module Bih
    module ReportMailbox
      module Reference
        PATTERN = /(?<![\p{L}\d])(?:BR|БР)[\s\-–]?(\d{4})[\s\-–](\d{1,6})(?!\d)/i

        def self.scan(text)
          text.to_s.scan(PATTERN).map { |year, number| format("BR-%<year>s-%<number>04d", year:, number: number.to_i) }.uniq
        end
      end
    end
  end
end