# frozen_string_literal: true

require "active_support/concern"

module Decidim
  module Bih
    # Applies a short-lived, unverified phone candidate to delivery D's
    # registration form. The handoff grants no authorization and changes only
    # a blank phone field, so every other field and consent built by the
    # registration controller remains intact and the citizen may edit it.
    module SocialRegistrationPrefill
      extend ActiveSupport::Concern

      SESSION_KEY = :mi_social_registration_prefill

      class_methods do
        def social_registration_prefill_available?
          defined?(Decidim::Bih::PhoneRegistrationForm)
        end
      end

      def new(...)
        result = super
        apply_social_registration_prefill
        result
      end

      private

      def apply_social_registration_prefill
        context = session.delete(SESSION_KEY)
        return unless valid_social_registration_prefill?(context)
        return unless @form
        return unless @form.respond_to?(:mobile_phone_number) && @form.respond_to?(:mobile_phone_number=)
        return if @form.mobile_phone_number.present?

        @form.mobile_phone_number = context.fetch("phone")
      end

      def valid_social_registration_prefill?(context)
        return false unless context.is_a?(Hash)
        return false unless context["organization_id"].to_i == current_organization.id

        expires_at = Time.zone.parse(context.fetch("expires_at").to_s)
        return false unless expires_at&.future?

        context.fetch("phone").to_s.match?(/\A\+\d{8,15}\z/)
      rescue ArgumentError, KeyError, TypeError
        false
      end
    end
  end
end
