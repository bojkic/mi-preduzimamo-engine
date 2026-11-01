# frozen_string_literal: true

module Decidim
  module Bih
    # Who may receive an MI newsletter — and, just as load-bearing, who this
    # audience can never be.
    #
    # Owner decision D12: **Decidim's newsletter carries MI platform news to
    # citizens; Odoo carries donations, donors and fundraising campaigns.** The
    # split is by audience and purpose, and it is enforced here rather than only
    # written down.
    #
    # The audience uses platform-citizenship facts only. Delivery requires a
    # proven current address, an enabled platform-news topic, and no active
    # SMTP suppression. The retired audience switch cannot bypass these checks.
    #
    # Read-only. It narrows a scope and never writes a preference, a newsletter
    # or a suppression.
    module NewsletterEligibility
      # What a donor-only cohort would be selected BY. Nothing in this module
      # may reference any of these, and no MI table may combine one with a
      # communication preference. The list is the executable form of D12's
      # "enforced in code, not merely documented".
      DONOR_CONCEPTS = %w(
        donor donors donation donations odoo fundraising campaign_donor
        giving_level donor_segment supporter_tier
      ).freeze

      # The provider and channel a newsletter is suppressed under. Mail leaves
      # through SMTP, not through the phone provider, so a Viber STOP must not
      # silence somebody's e-mail.
      SUPPRESSION_PROVIDER = "smtp"
      SUPPRESSION_CHANNEL = "email"

      module_function

      # @param scope [ActiveRecord::Relation] core's own recipient scope
      # @return [ActiveRecord::Relation] the same scope, narrowed
      def narrow(scope, organization:, now: Time.current)
        scope = exclude_suppressed(scope, organization:, now:)
        scope.where(id: proven_address_ids(scope)).where.not(
          id: Messaging::Preference.where(organization:, topic: "platform_news", state: "blocked").select(:decidim_user_id)
        )
      end

      # Compatibility accessor for hosts that still expose the retired switch.
      # Delivery eligibility no longer depends on it.
      def verified_audience?
        Decidim::Bih.newsletter_verified_audience == true
      end

      # A destination that has told us to stop is excluded whatever the switch
      # says. Computed by digest, so two written forms of one address are one
      # destination.
      def exclude_suppressed(scope, organization:, now: Time.current)
        digests = Messaging::Suppression.blocking(now)
                                        .where(organization:, provider: SUPPRESSION_PROVIDER, channel: SUPPRESSION_CHANNEL)
                                        .pluck(:destination_digest)
                                        .compact
        return scope if digests.empty?

        blocked = scope.filter_map do |user|
          user.id if digests.include?(digest_for(user))
        end
        blocked.empty? ? scope : scope.where.not(id: blocked)
      end

      def digest_for(user)
        return nil if user.email.blank?

        Messaging::SuppressionKey.digest(kind: "email", value: user.email)
      rescue ArgumentError
        nil
      end

      # A current address somebody proved. Changing the address loses the
      # proof, which is the point: an old confirmation is not evidence about a
      # new mailbox.
      def proven_address_ids(scope)
        scope.filter_map { |user| user.id if EmailConfirmation.confirmed?(user) }
      end

      # The D12 question itself is answered by NewsletterEligibilityBoundary,
      # deliberately in a separate file: this one must contain no such concept
      # AT ALL, so that a contract test can scan it for the absence.
    end
  end
end
