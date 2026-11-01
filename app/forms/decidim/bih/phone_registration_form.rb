# frozen_string_literal: true

require "securerandom"

module Decidim
  module Bih
    # The one-step /registracija form (delivery D, spec 5.2): name, an
    # UNPROVEN e-mail address, the phone number that becomes the login, a
    # komšiluk and the two consents.
    #
    # There is deliberately NO password attribute. The phone is the
    # credential; adding a password field here would reintroduce the two-step
    # sign-up this delivery replaces, and would give the citizen a second
    # secret nobody asked them to remember.
    #
    # `mimic :user` keeps the submitted field names as `user[...]`, which is
    # what Decidim's registration throttles, the shared registration views and
    # Decidim::Bih::SocialRegistrationPrefill (which writes
    # `mobile_phone_number` on this form) already expect — hence that attribute
    # name rather than a shorter `phone`.
    #
    # This object only judges the input. Creating the account, the pending
    # `sms` authorization and the komšiluk assignment belong to
    # Decidim::Bih::RegisterWithPhone.
    class PhoneRegistrationForm < Decidim::Form
      mimic :user

      # The shape Decidim::Verifications::Sms::MobilePhoneForm can hash and
      # send to. Keeping the two in step means a number accepted here is never
      # rejected one step later, at the point where the citizen is already
      # waiting for a message.
      E164 = /\A\+\d{8,15}\z/
      # A local BiH mobile number the way citizens type it: "06X XXX XXX".
      LOCAL_NUMBER = /\A0\d{8,9}\z/
      E164_PREFIX = "+387"
      NAME_MAX_LENGTH = 100
      # Handle for a name that survives neither transliteration nor
      # parameterisation (emoji, punctuation only).
      NICKNAME_FALLBACK_PREFIX = "gradjanin"

      attribute :name, String
      attribute :email, String
      attribute :mobile_phone_number, String
      attribute :komsiluk_id, Integer
      attribute :tos_agreement, Boolean
      attribute :newsletter, Boolean
      attribute :current_locale, String

      # The name format guard is Decidim's own (Decidim::UserBaseEntity
      # validates it unconditionally). Without it a name carrying markup
      # characters passes this form and then fails on Decidim::User#save,
      # turning a field-level message into a 500.
      validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }, format: { with: Decidim::User::REGEXP_NAME }
      validates :email, presence: true, format: { with: ::Devise.email_regexp }, unless: :simplified?
      validates :mobile_phone_number, presence: true
      validates :komsiluk_id, presence: true, unless: :simplified?
      validates :tos_agreement, allow_nil: false, acceptance: true

      validate :phone_is_plausible
      validate :email_is_free
      validate :phone_is_free
      validate :komsiluk_belongs_to_organization, unless: :simplified?

      def simplified? = Decidim::Bih.simplified_registration

      def email
        return "" if simplified?

        super.to_s.strip.downcase
      end

      # The phone as Decidim's SMS verification will store it. The stripping is
      # Decidim::Bih::SmsAuthorization's (the single source of truth for the
      # `unique_id` recipe), so the number this form checks for uniqueness is
      # byte-identical to the one the authorization row is keyed on. A local
      # 06x number is promoted to +387 first.
      def normalized_phone
        self.class.canonical_phone(mobile_phone_number)
      end

      # The one rule for turning what a citizen types into the number the
      # `sms` authorization is hashed from: strip to "+" and digits, and turn
      # a local BiH mobile ("06X XXX XXX") into E.164 ("+3876XXXXXXX"). Used
      # here and by the phone login, so a number accepted at registration is
      # recognised at login whichever way it is typed.
      def self.canonical_phone(value)
        raw = Decidim::Bih::SmsAuthorization.normalize(value)
        return "#{E164_PREFIX}#{raw.delete_prefix("0")}" if raw.match?(LOCAL_NUMBER)

        raw
      end

      # Decidim's nicknamize() parameterises the name, and parameterize
      # transliterates Latin accents only -- a Cyrillic name comes out EMPTY,
      # which then fails Decidim::User's nickname presence/format validation the
      # moment RegisterWithPhone saves the account. Fold to Latin first (the
      # engine's transliterator is lossless for Serbian), and fall back to a
      # generated handle when the name parameterises to nothing at all.
      # Memoised so the fallback stays the same handle across calls.
      def nickname
        @nickname ||= begin
          base = Decidim::Bih::Transliterator.to_latin(name.to_s).parameterize(separator: "_")
          base = "#{NICKNAME_FALLBACK_PREFIX}_#{SecureRandom.hex(3)}" if base.blank?
          # nicknamize still runs: it truncates to the column limit and
          # disambiguates against nicknames already taken in this organization.
          Decidim::UserBaseEntity.nicknamize(base, current_organization.id)
        end
      end

      def newsletter_at
        newsletter? ? Time.current : nil
      end

      # The chosen komšiluk, or nil when the id is blank or does not name a
      # komšiluk of this organization.
      def komsiluk
        return nil if komsiluk_id.blank?
        # Memoized per id rather than with `||=`: RegisterWithPhone's callers
        # (and its own tests) reassign komsiluk_id on a live form, and a plain
        # memo would keep answering with the previous komšiluk.
        return @komsiluk if defined?(@komsiluk) && @komsiluk_lookup_id == komsiluk_id

        @komsiluk_lookup_id = komsiluk_id
        @komsiluk = organization_komsiluci.find_by(id: komsiluk_id)
      end

      # Every komšiluk the citizen may pick, ordered by the Serbian name the
      # reference data is imported under (`name` is jsonb), matching the order
      # the komšiluk picker already uses elsewhere.
      def komsiluk_options
        organization_komsiluci.order(Arel.sql("name->>'sr'"))
      end

      private

      def organization_komsiluci
        Decidim::Bih::LocalArea.komsiluci.where(decidim_organization_id: current_organization.id)
      end

      def phone_is_plausible
        return if mobile_phone_number.blank?
        return if normalized_phone.match?(E164)

        errors.add(:mobile_phone_number, I18n.t("decidim.bih.registrations.errors.phone_invalid"))
      end

      # Devise stores e-mails lowercased and the (organization, email) index is
      # the one to hit, so this compares the downcased reader against the column
      # directly rather than wrapping it in LOWER().
      #
      # An invitation that was SENT but never ACCEPTED is not somebody's account
      # yet -- it is a row the foundation created for one of the launch
      # invitations. RegisterWithPhone adopts such a row, so it must not block a
      # citizen who registers without ever opening the invitation mail.
      # Everything else blocks, MANAGED (admin-created) accounts included: that
      # e-mail belongs to a real person an admin already registered.
      def email_is_free
        return if email.blank?

        same_email = Decidim::User.where(organization: current_organization, email:, deleted_at: nil)
        blocking = same_email.where(invitation_token: nil)
                             .or(same_email.where.not(invitation_accepted_at: nil))
        return unless blocking.exists?

        errors.add(:email, I18n.t("decidim.bih.registrations.errors.email_taken"))
      end

      # Only a GRANTED authorization blocks the number: an abandoned
      # verification must not squat a phone forever. Scoped to the
      # organization, because organizations are independent tenants.
      def phone_is_free
        return unless normalized_phone.match?(E164)
        return unless Decidim::Bih::SmsAuthorization.taken?(normalized_phone, organization: current_organization)

        errors.add(:mobile_phone_number, I18n.t("decidim.bih.registrations.errors.phone_taken"))
      end

      def komsiluk_belongs_to_organization
        return if komsiluk_id.blank? || komsiluk.present?

        errors.add(:komsiluk_id, I18n.t("decidim.bih.registrations.errors.komsiluk_invalid"))
      end
    end
  end
end
