# frozen_string_literal: true

require "minitest/autorun"
require "i18n"
require_relative "../../../../app/services/decidim/bih/onboarding/next_step"

class OnboardingLocalePathTest < Minitest::Test
  def setup
    @previous = I18n.available_locales
    I18n.available_locales = (@previous + [:sr, :"sr-Cyrl", :bs, :hr]).uniq
  end

  def teardown
    I18n.available_locales = @previous
  end

  def test_sms_workflow_uses_the_current_locale_for_each_platform_language
    %w(sr sr-Cyrl bs hr).each do |locale|
      I18n.with_locale(locale) do
        assert_equal "/#{locale}/sms/authorizations/new", Decidim::Bih::Onboarding::NextStep.sms_new_path
      end
    end
  end

  def test_invalid_locale_cannot_be_interpolated_into_a_redirect
    ["//example.invalid", "../users", "sr/other", ""].each do |locale|
      assert_raises(ArgumentError) { Decidim::Bih::Onboarding::NextStep.sms_new_path(locale:) }
    end
  end
end
