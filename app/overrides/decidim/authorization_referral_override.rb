# frozen_string_literal: true

# When a Decidim::Authorization becomes GRANTED (a citizen verifies):
#   (a) Set the :verified_citizen gamification badge in real time (binary 0/1).
#   (b) Award a one-time welcome bonus (action: "verification") via idempotency key.
#   (c) Reward any pending goodwill referral that invited them (Sybil gate),
#       and tell the referrer at once that the invitee has verified.
#   (d) postal_letter only: award the postal bonus and set the komšiluk from the
#       verified address.
#   (e) sms only: pay a komšiluk the citizen CHOSE before verification (never a
#       postally assigned one), and — on a phone-first host — publish the
#       welcome notification core skipped at e-mail confirmation.
# Every callback fires only on the nil→timestamp transition (first grant).
# Re-grants (renewal without the column being nil first) are skipped.
# Every side-effect is best-effort: a failure is logged and never breaks the
# verification flow itself.
module Decidim
  module Bih
    module Goodwill
      module AuthorizationReferralOverride
        def self.prepended(base)
          # Use after_commit (not after_save) so the referral reward job,
          # badge set, and welcome award fire only after the authorization row
          # is fully committed to the DB. This prevents race conditions where a
          # background job reads the Authorization before the transaction commits
          # and finds it still nil / in a previous state.
          # saved_change_to_granted_at? and saved_changes are preserved through
          # after_commit in Rails 7 (ActiveModel::Dirty guarantees this).
          base.after_commit :reward_goodwill_referral_if_granted
          base.after_commit :notify_referrer_of_verified_invitee
          base.after_commit :set_verified_citizen_badge_if_granted
          base.after_commit :award_verification_welcome_if_granted
          base.after_commit :award_postal_verified_if_granted
          base.after_commit :update_komsiluk_from_postal_if_granted
          base.after_commit :award_komsiluk_selected_if_verified
          base.after_commit :publish_phone_first_welcome_if_verified
        end

        def reward_goodwill_referral_if_granted
          return unless granted_at_transitioned_from_nil?

          # Delayed: lets a Sybil bot register+verify in one session; if no
          # genuine activity is detected by then, the minimum-activity gate in
          # Referrals#reward blocks the payout (see ReferralRewardJob).
          Decidim::Bih::Goodwill::ReferralRewardJob.set(wait: Decidim::Bih::Goodwill::ReferralRewardJob::REWARD_DELAY).perform_later(user_id: decidim_user_id)
        rescue StandardError => e
          Rails.logger.error("[goodwill] referral reward hook: #{e.class}: #{e.message}")
        end

        # The referrer hears about the invitee's FIRST verification right away
        # (bell only, no name, no points yet): the points follow after
        # REWARD_DELAY through the job above. Only the first granted
        # authorization of any kind counts — a citizen who verifies the phone
        # and later a postal letter is one registration, not two.
        def notify_referrer_of_verified_invitee
          return unless granted_at_transitioned_from_nil?
          return if Decidim::Authorization.where(decidim_user_id:).where.not(granted_at: nil).where.not(id:).exists?

          invitee = Decidim::User.find_by(id: decidim_user_id)
          return if invitee.blank?

          Decidim::Bih::Goodwill::Referrals.notify_referrer_of_verification(invitee)
        rescue StandardError => e
          Rails.logger.error("[goodwill] referral verified notice: #{e.class}")
        end

        # Set the binary :verified_citizen badge in real time so the core
        # /profiles/:nickname/badges page lights up immediately on verification,
        # without waiting for the nightly `decidim:gamification:reset_badges` run.
        def set_verified_citizen_badge_if_granted
          return unless granted_at_transitioned_from_nil?

          user = Decidim::User.find_by(id: decidim_user_id)
          return if user.blank?

          Decidim::Gamification.set_score(user, :verified_citizen, 1)
        rescue StandardError => e
          Rails.logger.error("[goodwill] verified_citizen badge set: #{e.class}: #{e.message}")
        end

        # Award a one-time verification welcome bonus. Idempotency key ensures
        # this fires exactly once even if the record is saved multiple times.
        def award_verification_welcome_if_granted
          return unless granted_at_transitioned_from_nil?

          user = Decidim::User.find_by(id: decidim_user_id)
          return if user.blank?

          Decidim::Bih::Goodwill::AwardDispatch.verification_welcome(user, user_id: decidim_user_id)
        rescue StandardError => e
          Rails.logger.error("[goodwill] verification welcome award: #{e.class}: #{e.message}")
        end

        # Award a one-time postal-verified bonus (50 pts).
        # Guarded by authorization name so this fires ONLY for postal_letter grants.
        # Idempotency key ensures exactly-once award even under re-save.
        def award_postal_verified_if_granted
          return unless granted_at_transitioned_from_nil?
          return unless name == "postal_letter"

          user = Decidim::User.find_by(id: decidim_user_id)
          return if user.blank?

          Decidim::Bih::Goodwill::AwardDispatch.postal_verified(user, user_id: decidim_user_id)
        rescue StandardError => e
          Rails.logger.error("[goodwill] postal_verified award: #{e.class}: #{e.message}")
        end

        # On postal_letter grant, geocode the verified address → set komšiluk
        # at the highest trust level (source: "postal"). Best-effort — a
        # geocoding failure never blocks the authorization grant.
        #
        # IMPORTANT: grant! clears verification_metadata before committing, so
        # by the time this after_commit fires, verification_metadata is {}. We
        # recover the mailing address from saved_changes["verification_metadata"][0]
        # (the pre-grant value). The address is used in-process and never re-stored.
        def update_komsiluk_from_postal_if_granted
          return unless granted_at_transitioned_from_nil?
          return unless name == "postal_letter"

          pre_grant_metadata = saved_changes.dig("verification_metadata", 0) || {}
          Decidim::Bih::Postal::PostalKomsilukService.call_with_address(
            user:,
            address: pre_grant_metadata["address"]
          )
        rescue StandardError => e
          Rails.logger.error("[postal] komsiluk update: #{e.class}: #{e.message}")
        end

        # A komšiluk chosen BEFORE the phone was verified earns nothing at pick
        # time (Sybil gate, spec 9.1) — pay it here, on the first granted `sms`.
        # KomsilukController pays an already-verified citizen itself, so both
        # paths can fire for the same person; the shared idempotency key
        # `komsiluk_selected:<uid>` keeps that to exactly one award.
        #
        # The profile lookup is a read-only find_by, never CitizenProfile
        # .for_user: that is find_or_create_by! and must not write from a
        # callback. "No row yet" and "row without a komšiluk" are the same
        # answer here — nothing to pay.
        #
        # source == "postal" is skipped: update_komsiluk_from_postal_if_granted
        # assigns that komšiluk from the verified mailing address, and the award
        # is for a komšiluk the citizen CHOSE. Paying it would hand 10 points to
        # someone who never opened the picker — a points-schedule change, not a
        # timing change.
        #
        # One interleaving under-pays and is accepted: if the picker commits its
        # first assignment in the instant between this hook reading the profile
        # and the controller reading the grant, neither side pays. It needs both
        # writes to land inside each other's read window, it can never DOUBLE
        # pay (the idempotency key forbids that), and the citizen recovers by
        # re-picking; a lock across two requests is not worth that.
        def award_komsiluk_selected_if_verified
          return unless granted_at_transitioned_from_nil?
          return unless name == "sms"

          user = Decidim::User.find_by(id: decidim_user_id)
          return if user.blank?

          profile = Decidim::Bih::CitizenProfile.find_by(
            decidim_organization_id: user.decidim_organization_id,
            decidim_user_id: user.id
          )
          return unless profile&.assigned?
          return if profile.source == "postal"

          Decidim::Bih::Goodwill::AwardDispatch.komsiluk_selected(user)
        rescue StandardError => e
          Rails.logger.error(
            "[goodwill] komsiluk_selected on verification: #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}"
          )
        end

        # Phone-first hosts deliberately skip Decidim's welcome notification at
        # e-mail confirmation (user_email_confirmation_override.rb): under
        # phone-first the verified phone, not the e-mail address, is the moment
        # the citizen joins. Publish it here instead — once, on the first
        # granted `sms`, with the organization's admin-edited welcome text and
        # the same payload core uses.
        def publish_phone_first_welcome_if_verified
          return unless granted_at_transitioned_from_nil?
          return unless name == "sms"
          return unless Decidim::Bih.phone_first_registration

          user = Decidim::User.find_by(id: decidim_user_id)
          return if user.blank?
          return unless user.organization.send_welcome_notification?

          Decidim::EventsManager.publish(
            event: "decidim.events.core.welcome_notification",
            event_class: Decidim::WelcomeNotificationEvent,
            resource: user,
            affected_users: [user],
            extra: { force_email: true }
          )
        rescue StandardError => e
          Rails.logger.error(
            "[goodwill] phone-first welcome: #{e.class}: #{Decidim::Bih::LogRedactor.error_message(e)}"
          )
        end

        private

        # True only on the FIRST grant: saved_change_to_granted_at? AND the
        # previous value was nil. This excludes re-grants where granted_at was
        # already set (renewals, re-saves) so we never double-award or double-badge.
        def granted_at_transitioned_from_nil?
          saved_change_to_granted_at? &&
            granted_at.present? &&
            saved_changes["granted_at"].first.nil?
        end
      end
    end
  end
end

Decidim::Authorization.prepend(Decidim::Bih::Goodwill::AuthorizationReferralOverride)
