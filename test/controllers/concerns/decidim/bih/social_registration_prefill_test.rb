# frozen_string_literal: true

require "test_helper"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time"
require "active_support/time"
require_relative "../../../../../app/controllers/concerns/decidim/bih/social_registration_prefill"

module Decidim
  module Bih
    class SocialRegistrationPrefillTest < Minitest::Test
      Organization = Struct.new(:id)
      Form = Struct.new(:name, :email, :mobile_phone_number, :tos_agreement, :newsletter, keyword_init: true)

      class BaseController
        attr_reader :session, :current_organization, :form

        def initialize(session:, organization:, existing_phone: nil)
          @session = session
          @current_organization = organization
          @existing_phone = existing_phone
        end

        def new
          @form = Form.new(
            name: "Mila",
            email: "mila@example.org",
            mobile_phone_number: @existing_phone,
            tos_agreement: true,
            newsletter: false
          )
          @form = form
        end
      end

      class Controller < BaseController
        prepend SocialRegistrationPrefill
      end

      def setup
        @previous_zone_default = Time.zone_default
        Time.zone_default = ActiveSupport::TimeZone["UTC"]
        @organization = Organization.new(42)
      end

      def teardown
        Time.zone_default = @previous_zone_default
      end

      def test_prefills_only_the_blank_phone_and_consumes_context
        session = { SocialRegistrationPrefill::SESSION_KEY => context }
        controller = Controller.new(session:, organization: @organization)

        form = controller.new

        assert_equal "+38765123456", form.mobile_phone_number
        assert_equal "Mila", form.name
        assert_equal "mila@example.org", form.email
        assert form.tos_agreement
        refute form.newsletter
        refute session.has_key?(SocialRegistrationPrefill::SESSION_KEY)
      end

      def test_existing_phone_wins_and_context_is_still_consumed
        session = { SocialRegistrationPrefill::SESSION_KEY => context }
        controller = Controller.new(session:, organization: @organization, existing_phone: "+38765999999")

        assert_equal "+38765999999", controller.new.mobile_phone_number
        refute session.has_key?(SocialRegistrationPrefill::SESSION_KEY)
      end

      def test_expired_or_cross_organization_context_never_prefills
        [context(expires_at: 1.second.ago), context(organization_id: 99), context.merge("expires_at" => "")].each do |invalid|
          session = { SocialRegistrationPrefill::SESSION_KEY => invalid }
          controller = Controller.new(session:, organization: @organization)

          assert_nil controller.new.mobile_phone_number
          refute session.has_key?(SocialRegistrationPrefill::SESSION_KEY)
        end
      end

      private

      def context(organization_id: @organization.id, expires_at: 5.minutes.from_now)
        {
          "organization_id" => organization_id,
          "phone" => "+38765123456",
          "expires_at" => expires_at.iso8601
        }
      end
    end
  end
end
