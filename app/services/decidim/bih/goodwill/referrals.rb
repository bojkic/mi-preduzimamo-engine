# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Referral attribution remains once per invited account. Settlement requires
      # current phone verification + neighborhood choice, the 24-hour delay, and
      # one of ten payment slots in the inviter's Sarajevo calendar month.
      # The oldest eligible attribution gets the next slot; overflow carries over.
      module Referrals
        # Monthly hard cap: max referrals a single referrer can be rewarded for
        # in one calendar month. Prevents a sustained invite-farm from draining
        # the ledger even if all the invitees eventually earn activity points.
        MONTHLY_CAP = 10

        # Where the invite landing page leaves the code and the moment it was
        # captured (CommunityHubController#show, tab "pozovi").
        SESSION_CODE_KEY = "goodwill_ref"
        SESSION_CAPTURED_AT_KEY = "goodwill_ref_at"

        # How long a captured code may still be spent by a registration.
        SESSION_WINDOW = 24.hours

        # Sessions written before the window existed carry no capture time.
        # They are not trusted blindly: the account still has to be minutes old.
        LEGACY_RECENCY = 30.minutes

        module_function

        # Remember an inbound ?ref= code in this browser's session so the
        # registration that follows (POST /registracija, or a Devise sign-up) can
        # attribute it. Nickname-shaped codes only — anything else is ignored.
        def capture_from_params(params, session)
          code = params[:ref].to_s.strip
          return if code.blank? || code.length > 60 || session.nil?

          session[SESSION_CODE_KEY] = code
          session[SESSION_CAPTURED_AT_KEY] = Time.current.utc.iso8601
          code
        end

        # Spend the referral code this browser is carrying on the account it
        # has just opened. ONE implementation for the two callers that have a
        # session and a fresh account in the same request:
        #
        #   * the Warden after_set_user hook (engine.rb) — every Decidim
        #     sign-up, which is signed in with the session still intact;
        #   * the one-step registration's POST (RegistrationsController
        #     #open_pending_page) — which is the ONLY chance that flow has.
        #     Nobody is signed in at /registracija, and the sign-in that comes
        #     later goes through CompletesPhoneAuthentication, which resets the
        #     session before it signs anybody in: by the time the hook fires
        #     there is no code left to read.
        #
        # Two guards, both kept from the hook this was extracted from: the code
        # may be at most SESSION_WINDOW old, and the account must have been
        # opened AFTER the link was clicked (a pre-existing account carrying an
        # old code in its session was not invited by it). A session with no
        # parseable capture time falls back to LEGACY_RECENCY rather than being
        # accepted blindly.
        #
        # Idempotent: a spent code is deleted from the session, so a second call
        # finds nothing, and #attribute itself refuses a second referral for the
        # same invitee.
        #
        # ATTRIBUTION ONLY. The referrer is REWARDED later, on the invitee's
        # grant plus the activity gate (#reward) — this call pays nothing.
        #
        # Returns the created Referral, or nil.
        def attribute_from_session(session, user)
          return nil if session.nil? || user.nil?

          code = session[SESSION_CODE_KEY]
          return nil if code.blank?

          case session_referral_verdict(session[SESSION_CAPTURED_AT_KEY], user)
          when :expired
            # Drop the stale keys rather than leave them to be re-read on every
            # later request.
            forget_session_referral(session)
            return nil
          when :refused
            return nil
          end

          referral = attribute(invitee: user, code:)
          forget_session_referral(session)
          referral
        rescue StandardError => e
          # The class and nothing else: a session carries whatever a URL put
          # there, and this line must never become the place a nickname, an
          # address or a number reaches the log.
          Rails.logger.error("[goodwill] referral capture: #{e.class}")
          nil
        end

        # :expired (the window closed, and the keys are spent), :refused (the
        # account is older than the click, or — with no capture time to go on —
        # older than the legacy fallback allows) or :attributable.
        def session_referral_verdict(raw_captured_at, user)
          captured_time = captured_at(raw_captured_at)
          return legacy_referral_verdict(user) if captured_time.nil?
          return :expired if Time.current - captured_time > SESSION_WINDOW
          return :refused if user.created_at && user.created_at < captured_time

          :attributable
        end

        # A session predating the window feature: no capture time to judge by,
        # so the account's own age is the only guard left.
        def legacy_referral_verdict(user)
          return :refused if user.created_at && user.created_at < LEGACY_RECENCY.ago

          :attributable
        end

        def captured_at(raw)
          return nil if raw.blank?

          Time.zone.parse(raw.to_s)
        rescue ArgumentError, TypeError
          nil
        end

        def forget_session_referral(session)
          session.delete(SESSION_CODE_KEY)
          session.delete(SESSION_CAPTURED_AT_KEY)
        end

        # Returns the created Referral, or nil if not attributable.
        def attribute(invitee:, code:)
          return nil if invitee.blank? || code.blank?

          organization = invitee.organization
          referrer = Decidim::User.find_by(organization:, nickname: code.to_s)
          return nil if referrer.nil? || referrer.id == invitee.id
          return nil if Referral.exists?(invitee_id: invitee.id)

          Referral.create!(organization:, referrer:, invitee:, status: "pending")
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        # Tell the referrer, in the bell only, that the invitee has verified and
        # that the referral points follow after ReferralRewardJob::REWARD_DELAY.
        # Nothing is paid here and no name is shown: a link shared on Facebook
        # can be used by anyone, and the referrer must not learn who from a
        # notification. The points and the wait are put into +extra+ at publish
        # time so the notice quotes what was true when it was sent. Returns the
        # pending Referral, or nil when there is nothing to tell. Never raises.
        def notify_referrer_of_verification(invitee)
          return nil if invitee.blank?

          referral = Referral.pending.find_by(invitee_id: invitee.id)
          return nil if referral.nil? || referral.referrer_id == invitee.id

          referrer = referral.referrer
          return nil if referrer.nil? || referrer.deleted? || referrer.blocked?

          Decidim::EventsManager.publish(
            event: "decidim.events.bih.goodwill.referral_verified",
            event_class: Decidim::Bih::Goodwill::ReferralVerifiedEvent,
            resource: referrer,
            affected_users: [referrer],
            force_send: true,
            extra: {
              points: EarningRules.new(organization: referrer.organization).points_for(:referral).to_i,
              hours: (ReferralRewardJob::REWARD_DELAY / 1.hour).to_i
            }
          )
          referral
        rescue StandardError => e
          Rails.logger.error("[goodwill] referral verified notice: #{e.class}")
          nil
        end

        # A worker for any invitee drains the same inviter queue. Admission,
        # monthly payment counting, source idempotency and status commit together.
        def reward(invitee)
          return unless invitee
          referral = Referral.find_by(invitee_id: invitee.id)
          return unless referral&.status == "pending"
          settle_queue(referral.referrer)
          referral.reload.status == "rewarded" ? referral : :pending_activity
        end

        def settle_queue(referrer, now: Time.current, limit: 100)
          return [] unless referrer&.organization
          account = Ledger.new.account_for(referrer)
          paid = []
          AccountLocks.with(account) do
            unless eligible_account?(referrer.reload, referrer.organization)
              Referral.pending.where(organization: referrer.organization, referrer:).order(:created_at, :id).limit(limit)
                .update_all(pending_reason: "waiting_eligibility", next_attempt_at: now + 1.day, updated_at: now)
              next
            end
            month_start = now.in_time_zone("Europe/Sarajevo").beginning_of_month
            month_end = month_start.next_month
            slots = [MONTHLY_CAP - Referral.rewarded.where(organization: referrer.organization, referrer:,
              rewarded_at: month_start...month_end).count, 0].max
            # oldest attribution is authoritative, never the triggering job order
            pending = Referral.pending.where(organization: referrer.organization, referrer:)
            # Query eligible candidates independently of the bounded maintenance
            # batch: 100 permanently ineligible older rows cannot starve #101.
            ready = pending.where(created_at: ..(now - ReferralRewardJob::REWARD_DELAY),
              invitee_id: eligible_invitee_ids(referrer.organization, before: now - ReferralRewardJob::REWARD_DELAY))
              .order(:created_at, :id).limit(slots).pluck(:id)
            due = pending.where("next_attempt_at IS NULL OR next_attempt_at <= ?", now).order(:created_at, :id).limit(limit).pluck(:id)
            pending.where(id: (ready + due).uniq).order(:created_at, :id).each do |referral|
              referral.lock!
              next unless referral.status == "pending"
              invitee = referral.invitee&.reload
              grant = eligible_account?(invitee, referral.organization) &&
                Decidim::Authorization.where(user: invitee, name: "sms").where.not(granted_at: nil).order(:granted_at).first
              unless grant && invitee_has_activity?(invitee)
                referral.update!(pending_reason: "waiting_eligibility", next_attempt_at: now + 1.day)
                next
              end
              available_at = [referral.created_at, grant.granted_at].max + ReferralRewardJob::REWARD_DELAY
              if available_at > now
                referral.update!(pending_reason: "waiting_delay", next_attempt_at: available_at)
                next
              end
              if slots.zero?
                referral.update!(pending_reason: "carryover", next_attempt_at: month_end)
                next
              end
              amount = EarningRules.new(organization: referral.organization).points_for(:referral)
              if amount <= 0
                referral.update!(pending_reason: "disabled", next_attempt_at: now + 1.day)
                next
              end
              key = IdempotencyKey.referral(invitee.id)
              transaction = Transaction.find_by(organization: referral.organization, idempotency_key: key)
              paid_at = transaction ? transaction.created_at : now
              transaction ||= Ledger.new.award(referrer, amount, reason: "referral", idempotency_key: key,
                metadata: { referral_id: referral.id, invitee_id: invitee.id, occurred_at: now.iso8601 })
              raise "referral award missing" unless transaction
              credited_account = SourceCreditCorrection.credited_account(transaction)
              raise "referral award recipient mismatch" unless credited_account.id == account.id && transaction.kind == "earn" && transaction.reason == "referral"
              referral.update!(status: "rewarded", rewarded_at: paid_at, ledger_transaction: transaction,
                               pending_reason: nil, next_attempt_at: nil)
              slots -= 1 if paid_at >= month_start && paid_at < month_end
              paid << referral
            end
          end
          paid
        end

        def eligible_invitee_ids(organization, before:)
          phones = Decidim::Authorization.where(name: "sms").where.not(granted_at: nil).where(granted_at: ..before).select(:decidim_user_id)
          neighbors = eligible_profiles(organization).select(:decidim_user_id)
          Decidim::User.not_user_group.where(organization:, deleted_at: nil, blocked: false).where(id: phones).where(id: neighbors).select(:id)
        end

        def eligible_account?(user, organization)
          user && user.organization == organization && !user.deleted? && !user.blocked? && !user.group?
        end

        # Owner policy: phone verification and choosing a neighborhood suffice.
        # Check source state directly; a delayed welcome award is not a new gate.
        def invitee_has_activity?(invitee)
          eligible_profiles(invitee.organization).where(user: invitee).exists?
        end

        def eligible_profiles(organization)
          CitizenProfile.where(organization:).joins(:komsiluk)
            .where(decidim_bih_local_areas: { decidim_organization_id: organization.id, kind: "komsiluk" })
        end

        def monthly_cap_reached?(referrer, now: Time.current)
          start_at = now.in_time_zone("Europe/Sarajevo").beginning_of_month
          Referral.rewarded.where(organization: referrer.organization, referrer:, rewarded_at: start_at...start_at.next_month).count >= MONTHLY_CAP
        end

        # Bounded recovery for missing jobs, changed eligibility and month rollover.
        # Due rows beyond this batch remain due for the next scheduled invocation.
        def retry_pending(organization:, limit: 200, now: Time.current)
          ids = Referral.pending.where(organization:).where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
            .order(:created_at, :id).limit(limit).pluck(:referrer_id).uniq
          ids.sum do |id|
            referrer = Decidim::User.find_by(id:)
            referrer ? settle_queue(referrer, now:).length : 0
          end
        end
      end
    end
  end
end
