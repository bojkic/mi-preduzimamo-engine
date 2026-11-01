# frozen_string_literal: true

module Decidim
  module Bih
    module Komsiluk
      # GSM extension characters occupy two septets. Unicode uses UTF-16 code
      # units, including two for supplementary characters. No transliteration:
      # the estimate describes the exact previewed and dispatched text.
      module SmsSegments
        BASIC = "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
        EXTENDED = "\f^{}\\[~]|€"

        module_function

        def estimate(text)
          chars = text.to_s.each_char.to_a
          gsm = chars.all? { |char| BASIC.include?(char) || EXTENDED.include?(char) }
          units = gsm ? gsm_units(chars) : text.to_s.encode("UTF-16BE").bytesize / 2
          single, multipart = gsm ? [160, 153] : [70, 67]
          { encoding: gsm ? "GSM-7" : "Unicode", units:, segments: segment_count(units, single, multipart) }
        end

        def gsm_units(chars)
          chars.sum { |char| EXTENDED.include?(char) ? 2 : 1 }
        end

        def segment_count(units, single, multipart)
          return 0 if units.zero?

          units <= single ? 1 : (units.to_f / multipart).ceil
        end
        private_class_method :gsm_units, :segment_count
      end
    end
  end
end
