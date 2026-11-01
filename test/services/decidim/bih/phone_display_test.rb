# frozen_string_literal: true

require "test_helper"
require_relative "../../../../app/services/decidim/bih/phone_display"

# The mask a citizen reads. It must never be confused with
# LogRedactor.mask_phone, which is for log lines only.
class PhoneDisplayTest < Minitest::Test
  def mask(value) = Decidim::Bih::PhoneDisplay.mask(value)

  def test_an_international_number_keeps_its_country_code_and_last_three_digits
    assert_equal "+387 6• ••• 456", mask("+38765123456")
  end

  def test_a_local_number_keeps_the_operator_prefix_and_last_three_digits
    assert_equal "06• ••• 004", mask("066900004")
  end

  def test_blank_input_masks_to_an_empty_string_not_a_placeholder
    assert_equal "", mask("")
    assert_equal "", mask(nil)
    assert_equal "", mask("   ")
  end

  # Short enough that there is no "middle" to hide: returning it whole would
  # print the number instead of masking it.
  def test_a_very_short_number_still_loses_all_but_its_last_digit
    assert_equal "••6", mask("456")
  end

  def test_separators_in_the_input_do_not_change_the_mask
    assert_equal mask("+38765123456"), mask("+387 65 123-456")
  end

  # The whole point is that the number cannot be read off the page.
  def test_the_masked_form_never_contains_the_hidden_digits
    masked = mask("+38765123456")

    refute_includes masked, "38765123456"
    refute_includes masked, "5123"
    assert_includes masked, "456"
  end
end
