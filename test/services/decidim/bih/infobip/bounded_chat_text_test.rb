# frozen_string_literal: true

require "test_helper"
require_relative "../../../../../app/services/decidim/bih/infobip/bounded_chat_text"

class BoundedChatTextTest < Minitest::Test
  Limiter = Decidim::Bih::Infobip::BoundedChatText

  def test_short_text_and_exact_byte_boundary_are_unchanged
    ["Kratak odgovor.", "ћ" * 2048, "x" * 4096].each do |text|
      assert_same text, Limiter.call(text)
    end
  end

  def test_multiple_urls_and_exact_commands_survive_both_caps_in_both_scripts
    ["Objašnjenje gradskog prevoza. ", "Објашњење градског превоза. "].each do |sentence|
      links = %w(https://mi.example.test/mapa?stanica=nas https://mi.example.test/registracija)
      command = "Odgovori: „Pošalji prijavu QA1234” ili „odustani”"
      text = (sentence * 200) + links.join("\n") + "\n#{command}"
      [1000, 2000, 4096].each do |cap|
        result = Limiter.call(text, max_chars: cap)
        assert result.valid_encoding?
        assert_operator result.length, :<=, cap
        assert_operator result.bytesize, :<=, 4096
        (links + [command]).each { |part| assert_includes result, part }
        assert_equal result, Limiter.call(result), "send boundary must not cut rendered output again"
      end
    end
  end

  def test_complete_negative_answer_and_consent_qualification_survive_late_in_reply
    qualifications = [
      "Nije potvrđen polazak nedjeljom.",
      "Не могу потврдити да аутобус стаје на тој станици.",
      "Slanje potvrdi samo ako pristaješ da tačna lokacija bude javna.",
      "Do not send unless you consent to the public location."
    ]
    qualifications.each do |qualification|
      text = ("Dodatno objašnjenje. " * 300) + qualification
      result = Limiter.call(text, max_chars: 1000)
      assert_includes result, qualification
      assert_operator result.length, :<=, 1000
    end
  end

  def test_fails_closed_when_required_instructions_cannot_fit
    text = "Odgovori: „#{"x" * 5000}”"
    assert_raises(Limiter::TooLong) { Limiter.call(text) }
    url = "https://mi.example.test/#{"x" * 5000}"
    assert_raises(Limiter::TooLong) { Limiter.call(url) }
  end

  def test_url_periods_do_not_split_a_qualified_sentence
    sentence = "Ne šalji prije provjere na https://mi.example.test/registracija i potvrde."
    result = Limiter.call(("Objašnjenje. " * 500) + sentence, max_chars: 1000)
    assert_includes result, sentence
  end
end
