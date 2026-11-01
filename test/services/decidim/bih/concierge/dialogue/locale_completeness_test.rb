# frozen_string_literal: true

require "test_helper"
require "yaml"
require "decidim/bih/transliterator"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/contracts"

module Decidim
  module Bih
    module Concierge
      module Dialogue
        # Milica's copy is written once in Serbian Latin (`sr`); `sr-Cyrl` is
        # generated from it, and `bs`, `hr` and `en` must carry every key. The
        # Serbian copy is ijekavian: an ekavian leftover reads as imported
        # from Serbia to a Bijeljina citizen, so the guard below rejects the
        # forms that have slipped in before (spec item 1.3).
        class LocaleCompletenessTest < Minitest::Test
          LOCALES_DIR = File.expand_path("../../../../../../config/locales", __dir__)
          # English has only `one`/`other` plural categories.
          SLAVIC_PLURAL_CATEGORIES = %w(few many).freeze
          # Latin ekavian forms with their ijekavian counterparts in the comment.
          EKAVIAN = [
            /\bbezbedn/i, # bezbjedn-
            /\bpre\s/i, # prije
            /\bovde\b/i, /\bgde\b/i, /\bnegde\b/i, /\bnigde\b/i, /\bsvugde\b/i, # ovdje, gdje, ...
            /\bvreme\b/i, # vrijeme
            /\breč\b/i, /\breči\b/i, # riječ, riječi
            /\buspeh/i, /\buspešn/i, # uspjeh, uspješn-
            /\bceo\b/i, /\bcel[aou]\b/i, /\bcelokupn/i, # cio, cijel-, cjelokupn-
            /\bsledeć/i, /\bposle\b/i, /\bposlednj/i, # sljedeć-, poslije, posljednj-
            /\bčovek\b/i, /\bdeo\b/i, # čovjek, dio
            /\bmesto\b/i, /\bmest[aou]\b/i, /\bumesto\b/i, # mjesto, umjesto
            /\bsvet\b/i, /\bsvetu\b/i, # svijet
            /\bobavešt/i, # obavješt-
            /\bnedelj/i, /\bmesec/i, /\bsreda\b/i, # nedjelj-, mjesec, srijeda
            /\bcen[aeiu]\b/i, /\bcenovnik/i, /\bocen/i, # cijena, cjenovnik, ocjen-
            /\brešenj/i, /\brešav/i, /\breši(?:ti|o|la|mo|)\b/i, # rješenj-, rješav-, riješi-
            /\bzahtev/i, /\bizveštaj/i, /\bprover/i, /\bprimer/i, # zahtjev, izvještaj, provjer-, primjer
            /\bsused/i, /\bpromen/i, /\bsavet/i, /\bvredn/i, /\bvredi\b/i, # susjed, promjen-, savjet, vrijedn-, vrijedi
            /\bdve\b/i, /\bhteo\b/i, /\bhtela\b/i, /\bželeo\b/i, /\bsmeo\b/i, # dvije, htio, htjela, želio, smio
            /\brazume/i, /\bvide(?:o|la|li|ti)\b/i, # razumije-, vidio/vidjela/vidjeti
            /\bdelimičn/i, /\bsvež/i # djelimičn-, svjež-
          ].freeze

          def test_every_serbian_concierge_key_exists_in_bosnian_croatian_and_english
            sr = leaves(concierge("sr"))
            %w(bs hr en).each do |locale|
              localized = leaves(concierge(locale))
              expected = locale == "en" ? sr.keys.reject { |key| SLAVIC_PLURAL_CATEGORIES.include?(key.split(".").last) } : sr.keys
              assert_empty expected - localized.keys, "#{locale} is missing concierge keys"
              expected.each do |key|
                assert localized.fetch(key).to_s.strip != "", "#{locale}:#{key} is blank"
                assert_equal placeholders(sr.fetch(key)), placeholders(localized.fetch(key)), "#{locale}:#{key} placeholders"
              end
            end
          end

          def test_the_cyrillic_concierge_copy_is_generated_from_the_latin_source
            assert_equal Decidim::Bih::Transliterator.deep(concierge("sr")), concierge("sr-Cyrl")
          end

          def test_the_serbian_concierge_and_dialogue_copy_is_ijekavian
            copy = leaves(concierge("sr")).merge(leaves(dialogue("sr")).transform_keys { |key| "dialogue.#{key}" })
            assert_empty ekavian_hits(copy), "ekavian forms in sr copy"
          end

          def test_the_cyrillic_concierge_and_dialogue_copy_is_ijekavian
            copy = leaves(concierge("sr-Cyrl")).merge(leaves(dialogue("sr-Cyrl")).transform_keys { |key| "dialogue.#{key}" })
            latinized = copy.transform_values { |text| Decidim::Bih::Transliterator.to_latin(text.to_s) }
            assert_empty ekavian_hits(latinized), "ekavian forms in sr-Cyrl copy"
          end

          def test_the_english_reply_can_say_its_facts_are_in_serbian
            Contracts::LOCALES.each do |locale|
              assert dialogue(locale).fetch("facts_in_source_language").to_s.strip != "", "#{locale} facts_in_source_language"
            end
            assert_includes dialogue("en").fetch("facts_in_source_language"), "Serbian"
          end

          private

          def concierge(locale)
            YAML.safe_load_file(File.join(LOCALES_DIR, "#{locale}.yml")).fetch(locale).dig("decidim", "bih", "concierge") || {}
          end

          def dialogue(locale)
            @dialogue ||= YAML.safe_load_file(File.join(LOCALES_DIR, "decidim_bih_dialogue.yml"))
            @dialogue.fetch(locale).dig("decidim", "bih", "dialogue") || {}
          end

          def leaves(node, prefix = nil, out = {})
            node.each do |key, value|
              path = [prefix, key].compact.join(".")
              value.is_a?(Hash) ? leaves(value, path, out) : out[path] = value
            end
            out
          end

          def placeholders(text)
            text.to_s.scan(/%\{([^}]+)\}/).flatten.sort
          end

          def ekavian_hits(copy)
            copy.flat_map do |key, text|
              EKAVIAN.filter_map { |pattern| "#{key}: #{text.to_s[pattern]}" if text.to_s.match?(pattern) }
            end
          end
        end
      end
    end
  end
end
