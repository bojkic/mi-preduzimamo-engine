# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Fires for exactly ONE delivery failure: the citizen has no saved phone
      # number at all (LaunchInvitationDeliveryJob's :no_phone). An
      # unconfigured Infobip client and a raised send are log-only there, on
      # purpose — telling a citizen who did verify their number to "confirm
      # your number" because OUR gateway had a bad minute is actively wrong,
      # not merely unhelpful. E-mail has already gone out unconditionally by
      # the time this fires; this is the extra nudge that gets a citizen with
      # no number on file to add one, so the next invitation-shaped message
      # reaches them.
      #
      # SimpleEvent (not the in-app-only BaseEvent + NotificationEvent pattern
      # used by the other Goodwill events in this directory) on purpose: this
      # is the one case in this task where BOTH an e-mail and a bell
      # notification are wanted, and SimpleEvent gives both for free from the
      # same locale keys (decidim.events.bih.launch_invitation_waiting_for_phone.*).
      #
      # resource_path/url/title are overridden directly to point at the
      # account page's setup checklist (Decidim::Bih.public_path("moj-nalog")
      # + "#zavrsi-nalog", the id account/show.html.erb gives that section) —
      # the fulfillment's RewardsCatalog entry can be an unpersisted config
      # Struct with no route of its own, so it is never a safe `resource:`
      # for an event ActiveJob will serialize; the resource passed to
      # EventsManager.publish is the affected Decidim::User instead (see the
      # job), and these overrides ignore it entirely in favour of the fixed,
      # anchored account-page destination.
      #
      # #resource_url needs the scheme+host (BaseEvent#organization already
      # resolves it from the Decidim::User resource via `resource.try
      # (:organization)`) because the mailer template's automatic CTA button
      # (decidim/notification_mailer/event_received.html.erb) renders it as an
      # <a href>, and a bare mount-relative path is meaningless in an e-mail —
      # there is no current page for it to resolve against.
      class LaunchInvitationWaitingForPhoneEvent < Decidim::Events::SimpleEvent
        ACCOUNT_SETUP_ANCHOR = "#zavrsi-nalog"

        def resource_path = "#{Decidim::Bih.public_path("moj-nalog")}#{ACCOUNT_SETUP_ANCHOR}"

        def resource_url
          "#{Decidim::Bih.public_url("moj-nalog", base_url: "https://#{organization.host}")}#{ACCOUNT_SETUP_ANCHOR}"
        end

        def resource_title = I18n.t("decidim.events.bih.launch_invitation_waiting_for_phone.title")
      end
    end
  end
end
