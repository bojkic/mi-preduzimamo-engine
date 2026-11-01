# frozen_string_literal: true

require "test_helper"
require "active_support/all"
require "decidim/bih"

class DecidimBihConfigFlagsTest < Minitest::Test
  def teardown
    Decidim::Bih.phone_first_registration = false
    Decidim::Bih.phone_first_registration_since = nil
    Decidim::Bih.registration_path = "/users/sign_up"
  end

  def test_phone_first_registration_defaults_to_false
    assert_equal false, Decidim::Bih.phone_first_registration
  end

  def test_registration_path_defaults_to_decidim_sign_up
    assert_equal "/users/sign_up", Decidim::Bih.registration_path
  end

  def test_cutoff_parses_the_since_string_as_utc_time
    Decidim::Bih.phone_first_registration_since = "2026-09-07 18:00:00"
    assert_equal Time.utc(2026, 9, 7, 18, 0, 0), Decidim::Bih.phone_first_registration_cutoff
  end

  def test_cutoff_is_nil_when_since_is_blank
    Decidim::Bih.phone_first_registration_since = ""
    assert_nil Decidim::Bih.phone_first_registration_cutoff
  end
end
