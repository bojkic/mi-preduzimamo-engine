# frozen_string_literal: true
require "minitest/autorun"
require_relative "../lib/decidim/bih/report_lifecycle"
class ReportLifecycleTest < Minitest::Test
  L = Decidim::Bih::ReportLifecycle
  def test_stage_and_closure_contract
    assert_equal %w(primljeno planirano proslijedjeno rijeseno zatvoreno), L::STAGES
    assert L.valid_closure?("zatvoreno", "duplikat")
    refute L.valid_closure?("rijeseno", "duplikat")
    refute L.valid_closure?("rijeseno", nil)
    refute L.allowed?("proslijedjeno", "primljeno")
    refute L.allowed?("rijeseno", "zatvoreno")
    assert L.allowed?("zatvoreno", "proslijedjeno")
  end
  def test_legacy_mapping_and_ambiguity
    assert_equal ["zatvoreno", "duplikat", false], map("odbijeno", duplicate: true)
    assert_equal ["zatvoreno", "bez_odgovora", false], map("odbijeno", auto_closed: true)
    assert_equal ["zatvoreno", "ostalo", true], map("odbijeno")
    assert_equal ["zatvoreno", "ostalo", true], map("odbijeno", rejection_basis: "invented")
    assert_equal ["proslijedjeno", nil, false], map("u_obradi", forwarded: true)
    assert_equal ["primljeno", nil, false], map("u_obradi")
    assert_equal ["rijeseno", "nepotvrdjeno", false], map("rijeseno")
    assert_nil L.notify?("primljeno", "primljeno")
    assert_equal :status_update, L.notify?("primljeno", "proslijedjeno")
  end
  def map(status, **values)
    L.from_legacy(status:, **{duplicate: false, forwarded: false, auto_closed: false}.merge(values))
  end
end
