# frozen_string_literal: true

require "digest"
# #phone_candidates leans on blank?/present?/compact_blank; declared here (like
# Digest above) so this file can be required on its own, as its unit test does.
require "active_support/core_ext/enumerable"
require "active_support/core_ext/object/blank"

module Decidim
  module Bih
    # Single source of truth for the SMS phone `unique_id` recipe.
    #
    # This MUST stay byte-identical to
    # +Decidim::Verifications::Sms::MobilePhoneForm#unique_id+, because the value
    # is compared against stored +Decidim::Authorization#unique_id+ rows. Any
    # divergence silently breaks BOTH OTP verification and the passwordless
    # phone-login lookup (the row is simply never found).
    #
    # The canonical recipe (decidim-verifications 0.31.7,
    # app/forms/decidim/verifications/sms/mobile_phone_form.rb) is:
    #
    #   mobile_phone_number = super.gsub(/[^+0-9]/, "")  # strip all but + and digits
    #   unique_id           = SHA256("#{mobile_phone_number}-#{secret_key_base}")
    #
    # NORMALIZATION CONTRACT:
    #   +unique_id_for+ applies the SAME normalization the form applies — it
    #   strips everything except "+" and digits (+to_s.gsub(/[^+0-9]/, "")+) and
    #   then hashes. This normalization is IDEMPOTENT, so callers that have
    #   already pre-normalized the phone with the identical gsub (e.g.
    #   PhoneSessionsController, which sanitizes +params[:phone]+ on entry) get a
    #   byte-identical result whether they pass the raw or the pre-normalized
    #   value. Callers that build their own format candidates (Viber
    #   AccountLinking) pass each candidate through here unchanged.
    #
    #   NOTE: this is intentionally NOT the digits-only normalization used by
    #   +Decidim::Bih::Viber::Linkage.normalize_phone+ (which strips "+" too).
    #   The form keeps a leading "+", so this helper must keep it as well.
    module SmsAuthorization
      # BiH country calling code, without the "+".
      COUNTRY_CODE = "387"

      module_function

      # Returns the SHA-256 `unique_id` for +phone+ using the canonical
      # MobilePhoneForm recipe. +phone+ is normalized here (strip all but "+" and
      # digits) before hashing; passing an already-normalized value is safe
      # (idempotent).
      def unique_id_for(phone)
        normalized = normalize(phone)
        Digest::SHA256.hexdigest("#{normalized}-#{Rails.application.secret_key_base}")
      end

      # The phone normalization the canonical MobilePhoneForm applies: keep only
      # "+" and digits. Exposed so callers can reuse the exact same stripping
      # when they need the normalized string itself (not just its hash).
      def normalize(phone)
        phone.to_s.gsub(/[^+0-9]/, "")
      end

      # Every phone SHAPE a stored authorization for +raw+ may be keyed on.
      #
      # This exists because the canonical MobilePhoneForm hashes the number AS
      # TYPED -- it only strips non-[+0-9] -- so the same citizen sits in the
      # table as "+3876XXXXXXX", "3876XXXXXXX" or "06XXXXXXX" depending on what
      # they happened to type at verification time. Delivery A's verification
      # flow stores as-typed numbers, so a lookup that hashes only one shape
      # silently misses the row and reports a verified phone as free.
      #
      # Bounded to at most four shapes, derived with the same rules as the
      # reverify candidate builder in PhoneVerificationActions and
      # Viber::AccountLinking: as typed (stripped), digits-only, E.164
      # "+387..." and local "0...". Returns [] for a blank number.
      def phone_candidates(raw)
        normalized = normalize(raw)
        return [] if normalized.blank?

        digits = normalized.delete_prefix("+")
        national =
          if digits.start_with?(COUNTRY_CODE)
            digits.delete_prefix(COUNTRY_CODE)
          elsif digits.start_with?("0")
            digits.delete_prefix("0")
          end

        candidates = [normalized, digits]
        candidates += ["+#{COUNTRY_CODE}#{national}", "#{COUNTRY_CODE}#{national}", "0#{national}"] if national.present?

        # A "+"-only input reaches here as "+" with an empty digits-only
        # shape. An empty candidate names no phone, and unique_id_candidates
        # would still hash it into a lookup key -- so it is dropped once,
        # here, rather than at each caller.
        candidates.compact_blank.uniq
      end

      # The `unique_id` of every shape #phone_candidates produces. This is what
      # callers must compare stored authorizations against.
      def unique_id_candidates(raw)
        phone_candidates(raw).map { |candidate| unique_id_for(candidate) }.uniq
      end

      # Whether +phone+ already belongs to a VERIFIED citizen of +organization+:
      # true only when a GRANTED `sms` Decidim::Authorization exists there whose
      # `unique_id` matches ANY shape the number could have been stored under
      # (see #phone_candidates). Backs the one-step /registracija form's
      # phone-uniqueness check. A PENDING (never granted) authorization does
      # NOT count as taken -- an abandoned verification must not permanently
      # squat a phone number -- and authorizations in another organization or
      # for a different phone never match (organizations are independent
      # tenants, so the same phone can register separately in each).
      def taken?(phone, organization:)
        unique_ids = unique_id_candidates(phone)
        return false if unique_ids.empty?

        Decidim::Authorization
          .joins(:user)
          .where(decidim_users: { decidim_organization_id: organization.id })
          .where(name: "sms", unique_id: unique_ids)
          .where.not(granted_at: nil)
          .exists?
      end
    end
  end
end
