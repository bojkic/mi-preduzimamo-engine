# frozen_string_literal: true

module Decidim
  module Bih
    module Sms
      # How many SMS a message actually costs.
      #
      # Our letters (š, đ, č, ć, ž) are NOT in the GSM-7 alphabet, so a message
      # containing even one of them is sent as UCS-2, where a single SMS carries
      # 70 characters instead of 160. A 150-character message therefore costs
      # THREE SMS with our diacritics and ONE without.
      #
      # That is why every SMS template on this platform is written without
      # diacritics, and why this counter runs before any mass send.
      module SegmentCounter
        # GSM 03.38 basic character set.
        GSM7_BASIC = (
          "@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?" \
            "¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà"
        ).chars.to_set.freeze

        # These exist in GSM-7 only via an escape byte, so they cost TWO.
        GSM7_EXTENDED = "^{}\\[~]|€".chars.to_set.freeze

        GSM7_SINGLE = 160
        GSM7_MULTIPART = 153
        UCS2_SINGLE = 70
        UCS2_MULTIPART = 67

        module_function

        def gsm7?(text)
          text.to_s.each_char.all? { |c| GSM7_BASIC.include?(c) || GSM7_EXTENDED.include?(c) }
        end

        # `characters` in the returned hash is always billable units in the
        # message's encoding, not a Ruby codepoint count: GSM-7 counts an
        # extended character twice, and UCS-2 counts a 16-bit code unit (an
        # astral-plane character, e.g. an emoji, is two).
        def for(text)
          text = text.to_s

          if gsm7?(text)
            characters = text.each_char.sum { |c| GSM7_EXTENDED.include?(c) ? 2 : 1 }
            { encoding: :gsm7, characters:, segments: segments(characters, GSM7_SINGLE, GSM7_MULTIPART) }
          else
            # UCS-2/UTF-16 bills 16-bit code units, not codepoints: a BMP
            # character (including all our diacritics) is one unit, but an
            # astral-plane character (e.g. an emoji) is a surrogate pair, i.e.
            # two units. text.length counts Ruby codepoints, which would
            # undercount those — the unsafe direction for a billing tool.
            characters = text.encode("UTF-16BE").bytesize / 2
            { encoding: :ucs2, characters:, segments: segments(characters, UCS2_SINGLE, UCS2_MULTIPART) }
          end
        end

        def segments(characters, single, multipart)
          return 1 if characters <= single

          (characters.to_f / multipart).ceil
        end
      end
    end
  end
end
