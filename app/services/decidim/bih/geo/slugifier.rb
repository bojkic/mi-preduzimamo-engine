# frozen_string_literal: true

module Decidim
  module Bih
    module Geo
      # Converts a UTF-8 area name into a URL-safe slug.
      #
      # Transliterates the common South-Slavic diacritics (č ć š ž đ) and any
      # Cyrillic that may creep in via a `naziv`, lowercases, replaces runs of
      # punctuation/whitespace with single hyphens, and trims leading/trailing
      # hyphens. Deterministic and lossless enough for slug generation (display
      # names keep their diacritics — only the slug is transliterated).
      #
      # Shared by the GeoJSON importer (decidim_bih:geo:import_areas) and the
      # non-polygon flat importer (decidim_bih:komsiluk:import_flat) so both
      # generate identical slugs for the same name.
      module Slugifier
        CYRILLIC_MAP = {
          "А" => "A", "Б" => "B", "В" => "V", "Г" => "G", "Д" => "D",
          "Е" => "E", "Ж" => "Z", "З" => "Z", "И" => "I", "Ј" => "J",
          "К" => "K", "Л" => "L", "М" => "M", "Н" => "N", "О" => "O",
          "П" => "P", "Р" => "R", "С" => "S", "Т" => "T", "У" => "U",
          "Ф" => "F", "Х" => "H", "Ц" => "C", "Ч" => "C", "Ш" => "S",
          "а" => "a", "б" => "b", "в" => "v", "г" => "g", "д" => "d",
          "е" => "e", "ж" => "z", "з" => "z", "и" => "i", "ј" => "j",
          "к" => "k", "л" => "l", "м" => "m", "н" => "n", "о" => "o",
          "п" => "p", "р" => "r", "с" => "s", "т" => "t", "у" => "u",
          "ф" => "f", "х" => "h", "ц" => "c", "ч" => "c", "ш" => "s"
        }.freeze

        module_function

        # Returns a URL-safe slug for `str`, or `fallback` if the result is empty.
        def call(str, fallback: "komsiluk")
          s = begin
            str.to_s.dup.unicode_normalize(:nfc)
          rescue StandardError
            str.to_s.dup
          end

          # South-Slavic Latin diacritics
          s.gsub!(/[čć]/i) { |c| c == c.upcase ? "C" : "c" }
          s.gsub!(/[š]/i) { |c| c == c.upcase ? "S" : "s" }
          s.gsub!(/[ž]/i) { |c| c == c.upcase ? "Z" : "z" }
          s.gsub!(/[đ]/i) { |c| c == c.upcase ? "D" : "d" }
          s.gsub!(/[Ð]/, "D")

          # Cyrillic pass (if any crept in via naziv)
          CYRILLIC_MAP.each { |from, to| s.gsub!(from, to) }

          s.downcase!
          s.gsub!(/[^a-z0-9]+/, "-")
          s.gsub!(/\A-+|-+\z/, "")
          s.presence || fallback
        end
      end
    end
  end
end
