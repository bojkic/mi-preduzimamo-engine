# frozen_string_literal: true

require "test_helper"
require "decidim/bih"

class DonationsProviderTest < Minitest::Test
  Organization = Struct.new(:id)

  def setup
    @previous_provider = Decidim::Bih.donations_provider
    @organization = Organization.new(7)
  end

  def teardown
    Decidim::Bih.donations_provider = @previous_provider
  end

  def test_provider_without_availability_capability_remains_global
    provider = Object.new
    Decidim::Bih.donations_provider = provider

    assert_same provider, Decidim::Bih.donations_provider_for(organization: @organization)
  end

  def test_keyword_availability_capability_is_enforced
    provider = Object.new
    provider.define_singleton_method(:available_for?) { |organization:| organization.id == 7 }
    Decidim::Bih.donations_provider = provider

    assert_same provider, Decidim::Bih.donations_provider_for(organization: @organization)
    assert_nil Decidim::Bih.donations_provider_for(organization: Organization.new(8))
  end

  def test_positional_availability_capability_is_backwards_compatible
    provider = Object.new
    provider.define_singleton_method(:available_for?) { |organization| organization.id == 7 }
    Decidim::Bih.donations_provider = provider

    assert_same provider, Decidim::Bih.donations_provider_for(organization: @organization)
    assert_nil Decidim::Bih.donations_provider_for(organization: Organization.new(8))
  end

  def test_availability_failure_fails_closed
    provider = Object.new
    provider.define_singleton_method(:available_for?) { |organization:| raise "unavailable #{organization.id}" }
    Decidim::Bih.donations_provider = provider

    assert_nil Decidim::Bih.donations_provider_for(organization: @organization)
  end
end
