# frozen_string_literal: true

module Decidim
  module Bih
    module Registration
      # Access to the "link sent" page for a citizen who is NOT signed in yet
      # (spec 5.4.3 / 5.4.4). The citizen stays signed out until the verify
      # link is consumed or the SMS code is confirmed, so the pending page
      # cannot be gated by a session the way every other page is -- it is
      # gated by one of these tokens instead.
      #
      # Two purposes, one difference that matters: the token minted into the
      # registering browser's OWN session (`session[:mi_pending_registration]`)
      # may hand that session over once the phone confirms; the token mailed
      # to an address nobody has proven (the `pending_token` URL param) NEVER
      # may. The e-mail link verifies neither the phone nor the address, so
      # all it can ever do is show the page. Separate signing purposes make
      # that structural: an e-mail token cannot be replayed as a session one,
      # because the purpose is part of what is signed.
      #
      # Controller contract: the SESSION-purpose token must only ever be read
      # from `session[:mi_pending_registration]` and NEVER accepted from a
      # request parameter. A param is something anyone can paste; the whole
      # point of the session variant is that it proves the request comes from
      # the browser that did the registering.
      #
      # Both are Rails signed ids: no table, no PII, nothing to log. The
      # module is read-only with respect to signing in -- it reports facts and
      # the controller decides what to do with them.
      module PendingAccess
        SESSION_PURPOSE = :pending_registration_session
        EMAIL_PURPOSE = :pending_registration_email

        # Which purpose grants the right to hand the session over. Ordered:
        # a token is resolved against each purpose in turn, and only one can
        # ever verify.
        HANDOFF_BY_PURPOSE = { SESSION_PURPOSE => true, EMAIL_PURPOSE => false }.freeze

        # A citizen who never finishes the phone step can come back to the
        # pending page from the e-mail for exactly as long as the stub itself
        # lives (PendingLifecycle::RETENTION): the link must never outlive the
        # account, nor die before it.
        TTL = Decidim::Bih::Registration::PendingLifecycle::RETENTION

        # A verify token that has just expired still counts as an open
        # hand-off window: the citizen may confirm the code in the last
        # seconds of its life and the poll that notices it arrives a moment
        # later. Five minutes is that gap, not an extension of the credential
        # -- LoginToken itself remains the only thing that can be consumed.
        HANDOFF_GRACE = 5.minutes

        module_function

        def mint_session(user) = user.signed_id(purpose: SESSION_PURPOSE, expires_in: TTL)

        def mint_email(user) = user.signed_id(purpose: EMAIL_PURPOSE, expires_in: TTL)

        # Resolves +token+ to `{ user:, handoff: }`, or nil when it must not
        # open the page at all: expired or tampered with, another
        # organization's citizen (organizations are independent tenants and a
        # token must never cross between them), a blocked or deleted account,
        # or -- unless +allow_verified+ -- an account that is no longer
        # pending. Only the status poll passes +allow_verified+, so that it
        # can report "verified" to the browser that was watching rather than
        # going blank at the moment of success.
        def resolve(token, organization:, allow_verified: false)
          return nil if token.blank? || organization.blank?

          HANDOFF_BY_PURPOSE.each do |purpose, handoff|
            user = Decidim::User.find_signed(token, purpose:)
            next if user.nil?
            return nil unless resolvable?(user, organization:, allow_verified:)

            return { user:, handoff: }
          end
          nil
        end

        # Internal: everything that must still be true of the account behind a
        # structurally valid token. Kept private so the only supported way to
        # ask "may this token open the page" is +resolve+, which also enforces
        # the purpose.
        def resolvable?(user, organization:, allow_verified:)
          return false unless user.decidim_organization_id == organization.id
          return false if user.blocked? || user.deleted?

          allow_verified || pending?(user)
        end
        private_class_method :resolvable?

        # Pending = registered, with an `sms` authorization row that has not
        # been granted yet. A citizen with no `sms` row at all is not pending
        # either: there is nothing for this page to wait for.
        def pending?(user)
          authorization = Decidim::Authorization.find_by(user:, name: "sms")
          authorization.present? && !authorization.granted?
        end

        # Whether a verify credential was live recently enough that signing
        # this browser in on success is still the citizen's own action rather
        # than a stale hand-off. Reads the newest verify token, live or just
        # consumed -- consuming it is exactly what opens the window, so this
        # must never filter on `consumed_at: nil`.
        #
        # ADVISORY TIMING ONLY, never sufficient on its own: possession of the
        # phone is proven by the LoginToken claim inside
        # CompletesPhoneAuthentication, and nothing here may stand in for it.
        def handoff_window_open?(user)
          latest = Decidim::Bih::LoginToken.where(user:, purpose: "verify")
                                           .order(created_at: :desc, id: :desc).first
          latest.present? && latest.expires_at > HANDOFF_GRACE.ago
        end
      end
    end
  end
end
