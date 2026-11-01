# frozen_string_literal: true

# The composer's audience statement, on core's own newsletter screen.
#
# Copying core's 103-line `select_recipients_to_deliver` template to insert a
# partial would be a fragile override to carry across Decidim upgrades. This
# one helper is the single place that callout text is built, so appending to
# it puts the same facts in front of the operator for one method's worth of
# surface area.
#
# What it appends is deliberately narrow and honest:
#   * that the count already excludes suppressed addresses,
#   * whether the proven-address narrowing is on,
#   * and the composer's disclaimer, because core's count is a preview too.
#
# It adds no cost line: an MI newsletter is SMTP, which is not billed per
# recipient, and a cost of "0" would be a claim about a bill nobody sends.
module Decidim
  module Bih
    module Admin
      module NewsletterRecipientsCalloutOverride
        def newsletter_recipients_count_callout_announcement
          announcement = super
          return announcement unless announcement.is_a?(Hash)

          announcement.merge(body: [announcement[:body], mi_newsletter_audience_note].compact.join(" "))
        rescue StandardError
          # A note is never worth failing the page an operator is working on.
          super
        end

        private

        def mi_newsletter_audience_note
          [
            I18n.t("decidim.bih.admin.newsletter.audience.suppression_applied"),
            audience_scope_note,
            Decidim::Bih::Messaging::AudienceEstimate::DISCLAIMER
          ].compact.join(" ")
        end

        def audience_scope_note
          key = if Decidim::Bih::NewsletterEligibility.verified_audience?
                  "proven_address_only"
                else
                  "all_subscribed"
                end
          I18n.t("decidim.bih.admin.newsletter.audience.#{key}")
        end
      end
    end
  end
end

Decidim::Admin::NewslettersHelper.prepend(
  Decidim::Bih::Admin::NewsletterRecipientsCalloutOverride
)
