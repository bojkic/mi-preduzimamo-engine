# frozen_string_literal: true

ENV["MT_NO_PLUGINS"] = "1"
gem "minitest", "~> 5.0"
require "test_helper"
require_relative "../../../../../../app/services/decidim/bih/concierge/dialogue/answer_contract"

class AnswerUrlsTest < Minitest::Test
  Dialogue = Decidim::Bih::Concierge::Dialogue
  ROUTE = "https://tenant.example/biceriseno/komsiluk"

  def setup
    @evidence = [{ "evidence" => [{ "id" => "policy", "source_url" => "https://outside.example/guide/full",
                                    "facts" => { "public_routes" => { "picker" => ROUTE } } }] }]
    deadline = Object.new
    deadline.define_singleton_method(:expired?) { false }
    @context = Struct.new(:deadline).new(deadline)
  end

  def test_exact_supported_absolute_relative_and_markdown_destinations
    [ROUTE, "/biceriseno/komsiluk", "[Izbor](#{ROUTE}).", "[Izbor](/biceriseno/komsiluk)"].each do |link|
      assert accepted?("Otvori: #{link}"), link
    end
  end

  def test_invented_relative_navigation_is_rejected
    ["/biceriseno/uputstva/komsiluk", "/%62iceriseno/uputstva/komsiluk", "/biceriseno/komsiluk/invented", "//outside.example/guide/full"].each do |link|
      assert_raises(Dialogue::Contracts::Invalid, link) { accepted?("Otvori #{link}") }
    end
  end

  def test_source_url_membership_is_exact_not_prefix_suffix_or_query_injection
    ["https://outside.example/guide", "https://outside.example/guide/full/fake", "#{ROUTE}?redirect=https://evil.example",
     "#{ROUTE}.evil", "#{ROUTE}#invented", "https://tenant.example.evil/biceriseno/komsiluk"].each do |link|
      assert_raises(Dialogue::Contracts::Invalid, link) { accepted?("Otvori #{link}") }
    end
    assert accepted?("Izvor: https://outside.example/guide/full.")
  end

  def test_literal_source_url_punctuation_is_not_an_authorized_prefix
    @evidence.first["evidence"].first["source_url"] = "https://outside.example/full!"
    assert accepted?("Izvor: https://outside.example/full!")
    assert_raises(Dialogue::Contracts::Invalid) { accepted?("Izvor: https://outside.example/full") }
  end

  def test_external_source_path_is_not_implicitly_authorized_on_tenant
    assert_raises(Dialogue::Contracts::Invalid) { accepted?("Otvori /guide/full") }
  end

  def test_supported_query_and_fragment_are_preserved_exactly
    @evidence.first["evidence"].first["facts"]["public_routes"]["picker"] = "#{ROUTE}?lang=sr#map"
    assert accepted?("Otvori #{ROUTE}?lang=sr#map")
    assert accepted?("Otvori /biceriseno/komsiluk?lang=sr#map")
    assert_raises(Dialogue::Contracts::Invalid) { accepted?("Otvori /biceriseno/komsiluk?lang=en#map") }
  end

  def test_ordinary_fraction_date_units_and_slash_prose_are_not_navigation
    assert accepted?("1/2; 18/9/2026; 30 km/h; ulica / naselje; korisno/nekorisno.")
  end

  def test_balanced_parentheses_in_source_url_are_not_lost
    @evidence.first["evidence"].first["source_url"] = "https://outside.example/guide_(full)"
    assert accepted?("Izvor: [vodič](https://outside.example/guide_(full)).")
    assert_raises(Dialogue::Contracts::Invalid) { accepted?("Izvor: https://outside.example/guide_(full") }
  end

  private

  def accepted?(answer)
    Dialogue::AnswerContract.new.call(payload: { "kind" => "answer", "answer" => answer, "evidence_ids" => ["policy"] },
                                      evidence: @evidence, message: "Gdje?", context: @context)
  end
end
