# frozen_string_literal: true

module Decidim
  module Bih
    # Ownership, not consent or channel reachability. Every read rechecks the
    # current grant; cached legacy delivery addresses can never override it.
    module VerifiedPhone
      module_function

      def phone_for(user:, organization:)
        return unless eligible_user?(user, organization)

        record = CitizenPhoneRecord.find_by(user:, organization:)
        phone = record&.phone
        phone if record&.verified_at.present? && current_grant(user:, organization:, phone:)
      rescue StandardError => e
        log_failure(user, e)
        nil
      end

      # Always give the provider an explicit international prefix. Its legacy
      # normalizer assumes any unprefixed foreign number is a BiH national one.
      # Bare ambiguous numbers require fresh proof in a supported representation.
      def delivery_phone_for(user:, organization:)
        raw = phone_for(user:, organization:)
        return if raw.blank?
        return raw if raw.match?(/\A\+[1-9][0-9]{7,14}\z/)
        return "+#{raw.delete_prefix("00")}" if raw.match?(/\A00[1-9][0-9]{7,14}\z/)

        country = Config.default_country_code.to_s
        return "+#{raw}" if raw.match?(/\A[1-9][0-9]{7,14}\z/) && raw.start_with?(country)
        return "+#{country}#{raw.delete_prefix("0")}" if raw.match?(/\A0[0-9]{8,9}\z/)

        nil
      end

      def consistent?(user:, organization:)
        phone = phone_for(user:, organization:)
        return false if phone.blank?

        contact = Viber::BusinessContact.find_by(user:, organization:)
        contact&.verified_at.present? && contact.phone == Viber::Linkage.normalize_phone(phone)
      rescue StandardError => e
        log_failure(user, e)
        false
      end

      # Call only after successful phone proof. A savepoint protects the valid
      # authentication transaction from an ancillary database write failure.
      # Stable rows retain their original verification timestamp on repeat login.
      def synchronize!(user:, organization:, phone:)
        return false unless eligible_user?(user, organization)

        result = false
        user.with_lock do
          ActiveRecord::Base.transaction(requires_new: true) do
            result = synchronize_locked(user:, organization:, phone:)
          end
        end
        result
      rescue StandardError => e
        log_failure(user, e)
        false
      end

      def synchronize_locked(user:, organization:, phone:)
        return false unless eligible_user?(user, organization)

        grant = current_grant(user:, organization:, phone:)
        return false unless grant

        normalized = SmsAuthorization.normalize(phone)
        digits = Viber::Linkage.normalize_phone(normalized)
        return false if digits.blank?

        save_destination!(CitizenPhoneRecord.find_or_initialize_by(user:), grant.granted_at, organization:, phone: normalized)
        save_destination!(Viber::BusinessContact.find_or_initialize_by(user:, organization:), grant.granted_at, phone: digits)
        true
      end
      private_class_method :synchronize_locked

      def save_destination!(record, verified_at, **attributes)
        record.assign_attributes(attributes)
        record.verified_at = verified_at if record.changed? || record.verified_at.blank?
        record.save! if record.new_record? || record.changed?
      end
      private_class_method :save_destination!

      # Called inside the same user lock as authorization removal. Do not erase
      # opaque Bot identity/history; remove its obsolete account phone binding.
      def revoke_destinations!(user:, organization:)
        raise ArgumentError, "organization mismatch" unless user.decidim_organization_id == organization.id

        CitizenPhoneRecord.where(user:).delete_all
        Viber::BusinessContact.where(user:, organization:).delete_all
        Viber::Linkage.where(user:, organization:).update_all(phone: nil, verified_at: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
      end

      def current_grant(user:, organization:, phone:)
        return if phone.blank?

        ids = SmsAuthorization.unique_id_candidates(phone)
        grants = Decidim::Authorization.joins(:user)
                                       .where(name: "sms", unique_id: ids, decidim_users: { decidim_organization_id: organization.id })
                                       .where.not(granted_at: nil).to_a
        active = grants.select { |grant| !grant.expired? && eligible_user?(grant.user, organization) }
        return unless active.one? && active.first.decidim_user_id == user.id

        # A second grant for this user, even with a different number, is
        # inconsistent data; never guess which destination is authoritative.
        return unless Decidim::Authorization.where(user:, name: "sms").count == 1

        active.first
      end
      private_class_method :current_grant

      def eligible_user?(user, organization)
        user.is_a?(Decidim::User) && organization.present? &&
          user.decidim_organization_id == organization.id &&
          user.active_for_authentication? && !user.blocked? && !user.deleted?
      end
      private_class_method :eligible_user?

      def log_failure(user, error)
        Rails.logger.error("[verified_phone] user=#{user&.id} error=#{error.class}")
      end
      private_class_method :log_failure
    end
  end
end
