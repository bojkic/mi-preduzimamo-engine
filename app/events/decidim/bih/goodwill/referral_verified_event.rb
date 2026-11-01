# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Bell notice to a referrer the moment an invited neighbour verifies:
      # "registered and verified, the points arrive in N hours". The points
      # themselves come later from ReferralRewardJob and produce their own
      # PointsEarnedEvent, so this event never mentions a balance.
      #
      # IN-APP ONLY (no e-mail), like PointsEarnedEvent and
      # DailyCapReachedEvent: information, not a reason to fill an inbox.
      # NO NAME: the invitee is never identified to the referrer here.
      #
      # The title ends in a link back to the invite tab, because being told an
      # invite worked is the moment a referrer is most likely to send another,
      # and until now this bell item led nowhere at all.
      #
      # The anchor has to live INSIDE the title: Decidim's notification cell
      # renders notification_title as HTML and never reads resource_path. That
      # is the same shape PointsEarnedEvent already uses. resource_path is
      # implemented anyway as the honest answer to "where does this notice
      # point", and the title is built from it, so the two can never disagree.
      class ReferralVerifiedEvent < Decidim::Events::BaseEvent
        include Decidim::Events::NotificationEvent

        # Both halves are locale strings and the path is built from the engine
        # mount, so nothing user-controlled reaches the markup; they are escaped
        # anyway so a translator cannot lose a literal & or <. The sanitize
        # allowlist permits <a href>, which is what lets the anchor survive.
        def notification_title
          base = I18n.t(
            "decidim.bih.goodwill.events.referral_verified.notification_title",
            points: extra["points"].to_i,
            hours: extra["hours"].to_i
          )
          path = resource_path
          html = if path.present?
                   # Escaped even though neither half is user input: a future
                   # translation containing & or < would otherwise be silently
                   # mangled by the sanitizer rather than rendered.
                   link = ERB::Util.html_escape(
                     I18n.t("decidim.bih.goodwill.events.referral_verified.invite_more")
                   )
                   %(#{ERB::Util.html_escape(base)} <a href="#{ERB::Util.html_escape(path)}">#{link}</a>)
                 else
                   base
                 end

          ActionController::Base.helpers.sanitize(html).html_safe
        end

        # A fixed destination, not a resource lookup: the referral itself has no
        # public page, and the useful place to land is the tab that hands the
        # citizen their link again. Never raises — a broken path must degrade to
        # a plain, unlinked bell item rather than blow up the whole panel.
        def resource_path
          Decidim::Bih.invite_path
        rescue StandardError
          nil
        end

        # Stays nil: this event is in-app only (NotificationEvent, no mailer),
        # so nothing ever needs the absolute form.
        def resource_url = nil

        def resource_title = nil
      end
    end
  end
end
