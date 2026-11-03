# frozen_string_literal: true

require "test_helper"
require "yaml"
require "decidim/bih/transliterator"

module Decidim
  module Bih
    class TransliteratorTest < Minitest::Test
      LOCALES_DIR = File.expand_path("../../../../config/locales", __dir__)
      def test_transliterates_latin_text_to_cyrillic
        assert_equal "Бијељина и Љубиње", Transliterator.call("Bijeljina i Ljubinje")
      end

      def test_preserves_interpolations_markup_and_liquid_tags
        source = 'Pozdrav %{name}, <a href="/x">otvori link</a> {{ value }} {% if ok %}'
        expected = 'Поздрав %{name}, <a href="/x">отвори линк</a> {{ value }} {% if ok %}'

        assert_equal expected, Transliterator.call(source)
      end

      def test_preserves_editor_client_placeholders
        assert_equal "Наслов %level%", Transliterator.call("Naslov %level%")
        assert_equal "Промијени величину (%position%)", Transliterator.call("Promijeni veličinu (%position%)")
      end

      def test_editor_placeholders_do_not_swallow_adjacent_strftime_directives
        ["%Y%m%d", "%d%m%Y", "%_d%m", "%-d%-m%Y", "%03d%m"].each do |format|
          assert_equal format, Transliterator.call(format)
        end
      end

      def test_preserves_latin_brand_tokens
        assert_equal "Свака ознака води у Odoo кампању", Transliterator.call("Svaka oznaka vodi u Odoo kampanju")
        assert_equal "Web chat на сајту", Transliterator.call("Web chat na sajtu")
        assert_equal "#zanasuzajednicu", Transliterator.call("#zanasuzajednicu")
        assert_equal "Слика у формату WebP", Transliterator.call("Slika u formatu WebP")
        assert_equal "нпр. BR-2026-0001", Transliterator.call("npr. BR-2026-0001")
      end

      def test_preserves_funder_brand_names
        # The visibility guidelines of the CSI grant (CommunityPartner, 4.6.2026)
        # require the original word order and spelling of every funder name; a
        # phonetic Cyrillic rendering ("ЦИВИЦУС", "ТецхСоуп") alters the brand.
        assert_equal "Платформу подржава COMMUNITY Community Support Initiative (CSI).",
                     Transliterator.call("Platformu podržava COMMUNITY Community Support Initiative (CSI).")
        assert_equal "шема Community Spark, Regional Community Support, CommunityPartner и CommunityTools, Community Participation Program",
                     Transliterator.call("šema Community Spark, Regional Community Support, CommunityPartner i CommunityTools, Community Participation Program")
        # A Latin brand takes a Cyrillic case ending after the hyphen.
        assert_equal "у партнерству са COMMUNITY-ом", Transliterator.call("u partnerstvu sa COMMUNITY-om")
      end

      def test_preserves_loanword_tokens_appearing_in_source_locale
        # These tokens occur in config/locales/sr.yml; transliterating them
        # yielded nonsense ("Инфобип", "Вибер цхат", "wеб образац").
        assert_equal "Infobip (Вибер и СМС)", Transliterator.call("Infobip (Viber i SMS)")
        assert_equal "Вибер chat", Transliterator.call("Viber chat")
        assert_equal "web образац за пријаву", Transliterator.call("web obrazac za prijavu")
        assert_equal "провјерити Infobip стање испоруке", Transliterator.call("provjeriti Infobip stanje isporuke")
        # Channel brands and the integration term that names their routing.
        # Transliterated they became "WхатсАпп", "Мессенгер" and "wебхоок" —
        # unreadable, and in the brands' case wrong: they are trademarks with
        # one spelling.
        assert_equal "Потврди WhatsApp, Messenger и webhook рутирање",
                     Transliterator.call("Potvrdi WhatsApp, Messenger i webhook rutiranje")
        # The declined brand, exactly as the phone-verification page's code
        # entry uses it (R-D9). \b ends the WhatsApp token before the "a", so
        # without its own PRESERVED_WORDS entry the genitive came out
        # "WhatsAppа" with a Cyrillic tail on a trademark.
        assert_equal "Имам код из WhatsAppa",
                     Transliterator.call("Imam kod iz WhatsAppa")
        assert_equal "Имам код из WhatsAppa или СМС-а",
                     Transliterator.call("Imam kod iz WhatsAppa ili SMS-a")
      end

      def test_only_standalone_loanword_tokens_are_preserved
        # The \b boundaries mean inflected/derived words still transliterate;
        # only the exact loanword token stays Latin.
        assert_equal "цхатови", Transliterator.call("chatovi")
        assert_equal "wебинар", Transliterator.call("webinar")
      end

      def test_preserves_technical_tokens_urls_and_env_vars
        source = "Postavite GEMINI_BASE_URL na Vertex host " \
                 "(https://aiplatform.googleapis.com)."
        expected = "Поставите GEMINI_BASE_URL на Vertex хост " \
                   "(https://aiplatform.googleapis.com)."

        assert_equal expected, Transliterator.call(source)
        assert_equal "Gemini и AI Studio", Transliterator.call("Gemini i AI Studio")
        assert_equal "API кључ", Transliterator.call("API ključ")
      end

      def test_preserves_strftime_directives_in_date_format_strings
        # Date/time format strings (date.formats.*, time.formats.*) carry
        # strftime directives whose ASCII letters are also transliterable; the
        # directive letters must stay Latin or strftime breaks, while %B/%A
        # still localize from month_names/day_names at render time.
        assert_equal "%d/%m/%Y", Transliterator.call("%d/%m/%Y")
        assert_equal "%B %e, %Y", Transliterator.call("%B %e, %Y")
        assert_equal "%a %d %b %Y %H:%M:%S %Z", Transliterator.call("%a %d %b %Y %H:%M:%S %Z")
        assert_equal "%-d. %B %Y.", Transliterator.call("%-d. %B %Y.")
        # %{...} interpolations still win over the bare-directive branch.
        assert_equal "Види %{count} дана", Transliterator.call("Vidi %{count} dana")
      end

      # Cyrillic -> Latin reverse transliteration must round-trip realistic
      # MZ/komšiluk and president names (title-case, all-caps, lowercase),
      # with correct digraph casing: title-case "Nj"/"Lj"/"Dž" normally and
      # fully uppercased "NJ"/"LJ"/"DŽ" inside an all-caps word.
      def test_to_latin_round_trips_mz_like_names
        names = [
          "Bijeljina", "Ljubinje", "Dvorovi", "Centar", "Đorđe Đurić",
          "NJEGOŠ", "DŽEMAT", "LJUBINJE", "MZ DVOROVI",
          "Njiva", "Ljiljana", "Džematska", "Šljiva", "Čađavica",
          "Mjesna Zajednica Njegoš", "Stari Ujak Lj"
        ]

        names.each do |latin|
          cyrillic = Transliterator.call(latin)
          assert_equal latin, Transliterator.to_latin(cyrillic),
                       "round-trip failed for #{latin.inspect} (via #{cyrillic.inspect})"
        end
      end

      def test_to_latin_uppercases_digraph_in_all_caps_context
        # All-caps Cyrillic digraph words must fully uppercase the Latin digraph.
        assert_equal "NJEGOŠ", Transliterator.to_latin("ЊЕГОШ")
        assert_equal "DŽEMAT", Transliterator.to_latin("ЏЕМАТ")
        assert_equal "LJUBINJE", Transliterator.to_latin("ЉУБИЊЕ")
      end

      def test_to_latin_title_cases_digraph_outside_all_caps
        # Title-case / lowercase words keep the title-case "Nj"/"Lj"/"Dž".
        assert_equal "Njiva", Transliterator.to_latin("Њива")
        assert_equal "Ljubinje", Transliterator.to_latin("Љубиње")
        assert_equal "Džematska", Transliterator.to_latin("Џематска")
        assert_equal "njiva", Transliterator.to_latin("њива")
      end

      def test_to_latin_passes_latin_input_through_unchanged
        assert_equal "Bijeljina", Transliterator.to_latin("Bijeljina")
        assert_equal "Centar 2", Transliterator.to_latin("Centar 2")
      end

      def test_localize_renders_target_script_and_is_idempotent
        # Cyrillic-stored value displays Latin under Latin locales...
        %w(sr bs hr en).each do |locale|
          assert_equal "Njiva", Transliterator.localize("Њива", locale:),
                       "expected Latin under #{locale}"
        end
        # ...and Cyrillic under sr-Cyrl.
        assert_equal "Њива", Transliterator.localize("Njiva", locale: "sr-Cyrl")

        # Idempotent when the value is already in the target script.
        assert_equal "Njiva", Transliterator.localize("Njiva", locale: "sr")
        assert_equal "Њива", Transliterator.localize("Њива", locale: "sr-Cyrl")
      end

      def test_localize_returns_non_string_input_unchanged
        assert_nil Transliterator.localize(nil, locale: "sr")
        assert_equal 42, Transliterator.localize(42, locale: "sr-Cyrl")
      end

      def test_deep_transliterates_values_without_changing_i18n_keys
        source = {
          "decidim.bih.title" => "Novi prijedlog",
          :nested => ["Džep", { "cta" => "Pošalji" }]
        }

        expected = {
          "decidim.bih.title" => "Нови приједлог",
          :nested => ["Џеп", { "cta" => "Пошаљи" }]
        }

        assert_equal expected, Transliterator.deep(source)
      end

      # Guard: sr-Cyrl.yml is GENERATED from sr.yml by `rake decidim_bih:cyrillize`
      # and must never be hand-edited (hand-edits silently revert on the next
      # regeneration). Regenerating must be a no-op: the committed Cyrillic
      # content must equal cyrillize(sr.yml). We compare the parsed data
      # structures so the assertion is robust to header/formatting/line-width.
      def test_committed_cyrillic_locale_equals_regenerated_output
        source = YAML.safe_load_file(File.join(LOCALES_DIR, "sr.yml"))
        committed = YAML.safe_load_file(File.join(LOCALES_DIR, "sr-Cyrl.yml"))

        regenerated = { "sr-Cyrl" => Transliterator.deep(source.fetch("sr")) }

        assert_equal regenerated, committed,
                     "config/locales/sr-Cyrl.yml is out of sync with cyrillize(sr.yml). " \
                     "Do not hand-edit sr-Cyrl.yml — edit sr.yml and run `rake decidim_bih:cyrillize`."
      end
    end
  end
end
