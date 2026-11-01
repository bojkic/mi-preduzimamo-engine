# frozen_string_literal: true

module Decidim
  module Bih
    # Namespace for the outbound SMS machinery, and the home of the one rule
    # every SMS sender on this platform has to obey.
    module Sms
      # Serbian Cyrillic is UCS-2 on the wire, which cuts an SMS segment from
      # 160 characters to 70 — and this platform's SMS copy is deliberately
      # written as diacritic-free Latin, so sr-Cyrl.yml holds a machine
      # transliteration of it that reads as misspelled Cyrillic ("вази",
      # "Немас"). Serbian Latin says the same thing correctly, in GSM-7, in
      # one segment. Every other locale is passed through untouched, and
      # Viber (a smartphone channel with no segment limit) keeps the citizen's
      # own script — this helper is for the SMS leg only.
      def self.latin_locale_for(locale = I18n.locale)
        locale.to_s == "sr-Cyrl" ? :sr : locale
      end
    end
  end
end
