# frozen_string_literal: true

require "test_helper"
require "active_support/concern"
require File.expand_path("../../../../../app/controllers/concerns/decidim/bih/current_organization_user", __dir__)

class CurrentOrganizationUserTest < Minitest::Test
  Organization = Struct.new(:id)
  UserWithOrganization = Struct.new(:id, :organization)
  UserWithOrganizationId = Struct.new(:id, :decidim_organization_id)

  class Controller
    include Decidim::Bih::CurrentOrganizationUser

    attr_accessor :user, :organization

    def current_user
      user
    end

    def current_organization
      organization
    end

    public :current_organization_user,
           :current_organization_user_signed_in?,
           :current_organization_user_verified?
  end

  def setup
    @organization = Organization.new(1)
    @other_organization = Organization.new(2)
    @controller = Controller.new
    @controller.organization = @organization
  end

  def test_returns_user_when_user_belongs_to_current_organization
    user = UserWithOrganization.new(10, @organization)
    @controller.user = user

    assert_same user, @controller.current_organization_user
    assert @controller.current_organization_user_signed_in?
  end

  def test_returns_user_when_user_has_matching_organization_id
    user = UserWithOrganizationId.new(10, @organization.id)
    @controller.user = user

    assert_same user, @controller.current_organization_user
  end

  def test_returns_nil_for_cross_organization_user
    @controller.user = UserWithOrganization.new(10, @other_organization)

    assert_nil @controller.current_organization_user
    refute @controller.current_organization_user_signed_in?
  end

  def test_returns_nil_without_user
    assert_nil @controller.current_organization_user
  end

  def test_verified_is_false_without_decidim_authorization_constant
    @controller.user = UserWithOrganization.new(10, @organization)

    refute @controller.current_organization_user_verified?
  end
end
