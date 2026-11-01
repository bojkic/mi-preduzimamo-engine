# frozen_string_literal: true

module Decidim
  module Bih
    # Whether the citizen's CURRENT e-mail address is proven, independently of
    # Devise's confirmed_at. Phone-first registration sets confirmed_at at
    # sign-up (skip_confirmation!) to activate the account, so confirmed_at
    # no longer means "clicked the e-mail link". Password reset relies on this
    # module, never on confirmed_at (spec 9.2).
    #
    # An address counts as proven when it was recorded here (KEY, matched
    # case-insensitively against the user's CURRENT e-mail, so changing the
    # address loses the proof), or when the account is grandfathered — see
    # #grandfathered? for what a nil phone_first_registration_cutoff means on a
    # phone-first host versus a stock one.
    module EmailConfirmation
      KEY = "mi_email_confirmed"

      module_function

      def confirmed?(user)
        return false unless user.is_a?(Decidim::User) && user.email.present?

        data = user.extended_data.to_h[KEY]
        return true if data.is_a?(Hash) && data["address"].to_s.casecmp?(user.email.to_s)

        grandfathered?(user)
      end

      def mark_confirmed!(user, address = user.email)
        return if user.blank? || address.blank?

        payload = user.extended_data.to_h.merge(
          KEY => { "address" => address.to_s.downcase, "at" => Time.current.utc.iso8601 }
        )
        user.update_column(:extended_data, payload) # rubocop:disable Rails/SkipsModelValidations
      end

      # confirmed_at set BEFORE phone-first went live could only come from the
      # Devise link or an admin; both are acceptable proof. After the cutoff
      # confirmed_at is set by skip_confirmation! and proves nothing.
      #
      # A nil cutoff means "no cutoff", but only for a host that does NOT run
      # phone-first: there, every confirmed_at came from the Devise link, so
      # grandfathering all of them is right and keeps stock hosts untouched.
      # On a phone-first host a nil cutoff must NOT grandfather anything — with
      # skip_confirmation! at sign-up that would hand a proven e-mail to every
      # account on the platform, which is exactly the hole this module closes.
      # A phone-first host that forgets phone_first_registration_since therefore
      # fails closed (nobody proven) instead of open (everybody proven).
      def grandfathered?(user)
        return false if user.confirmed_at.blank?

        cutoff = Decidim::Bih.phone_first_registration_cutoff
        return false if cutoff.nil? && Decidim::Bih.phone_first_registration

        cutoff.nil? || user.confirmed_at < cutoff
      end
      private_class_method :grandfathered?
    end
  end
end
