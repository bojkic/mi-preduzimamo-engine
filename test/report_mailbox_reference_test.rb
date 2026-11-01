# frozen_string_literal: true

require "minitest/autorun"
require_relative "../app/services/decidim/bih/report_mailbox/reference"
class ReportMailboxReferenceTest < Minitest::Test
  def test_grouped_and_cyrillic_references
    scanner = Decidim::Bih::ReportMailbox::Reference
    assert_equal %w(BR-2026-0034 BR-2026-0035 BR-2026-0072), scanner.scan("BR 2026 0034, br–2026–35, БР-2026-72")
    assert_empty scanner.scan("Predmet 02-372-1234/26")
  end
end
