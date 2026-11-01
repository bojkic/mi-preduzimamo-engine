# frozen_string_literal: true

module Decidim
  module Bih
    module Registration
      # How long an unconfirmed one-step registration ("stub") lives, and what
      # happens to it along the way. Owner decision 2026-09-10:
      #
      #   15 min  first reminder e-mail (ResumeRegistrationEmailJob, unchanged)
      #   day 5   second e-mail: "removed in 48 hours", resume link
      #   day 7   hard delete, silent — unless a verify link is still live
      #
      # Everything is measured from the account's created_at, never from the
      # last message: pressing "send again" does not restart the week.
      #
      # A stub holds NOTHING: a pending `sms` authorization and no granted one
      # of any kind, no session ever opened, no authority, no points. That is
      # the same test the pending page applies before "Počni ispočetka", and
      # both call this one method so they can never disagree.
      #
      # PRIVACY: nothing here logs or returns a name, an address, a number or
      # a token — ids and counts only.
      module PendingLifecycle
        RETENTION = 7.days
        SECOND_REMINDER_AT = 5.days
        FINAL_NOTICE_SENT_AT_KEY = "mi_final_notice_sent_at"

        module_function

        def stub?(user)
          return false unless user.is_a?(Decidim::User) && user.persisted?
          return false unless Decidim::Authorization.exists?(user:, name: "sms", granted_at: nil)
          return false if Decidim::Authorization.where(user:).where.not(granted_at: nil).exists?
          return false unless user.sign_in_count.to_i.zero?
          return false if privileged?(user)

          !goodwill_earned?(user)
        end

        # One pass over the organization's stubs. Dry-run by default: counts
        # what it WOULD do and touches nothing. Each account is its own unit of
        # work — one failure is counted, logged by id and class, and the pass
        # continues. The run itself is recorded in the operator audit log with
        # counts only.
        def sweep(organization:, dry_run: true, now: Time.current)
          counts = { scanned: 0, reminded: 0, deleted: 0, skipped_live_link: 0, refused: 0, failed: 0, dry_run: }
          # find_each batches by primary key and ignores (and warns about) any
          # other order; pending_scope's explicit order is for callers that
          # list, not for this loop.
          pending_scope(organization).unscope(:order).find_each do |user|
            counts[:scanned] += 1
            next unless stub?(user)

            age = now - user.created_at
            if age >= RETENTION
              delete_stub!(user, counts, dry_run:)
            elsif age >= SECOND_REMINDER_AT
              remind!(user, counts, dry_run:)
            end
          rescue StandardError => e
            counts[:failed] += 1
            Rails.logger.error("[registracija] lifecycle sweep failed for user #{user.id}: #{e.class}")
          end
          Decidim::Bih::OperatorAuditEvent.record!(
            organization:, actor: nil, event_type: "registration_pending_swept",
            metadata: counts.transform_keys(&:to_s)
          )
          counts
        end

        def remind!(user, counts, dry_run:)
          return if user.email.blank?
          return if user.extended_data.to_h[FINAL_NOTICE_SENT_AT_KEY].present?

          counts[:reminded] += 1
          return if dry_run

          token = PendingAccess.mint_email(user)
          Decidim::Bih::RegistrationMailer.final_notice(user, token).deliver_now
          # update_column, not update!: a delivery receipt about a row this
          # sweep did not otherwise touch, and a user record that would not
          # validate today must not turn "sent" into "send again".
          user.update_column( # rubocop:disable Rails/SkipsModelValidations
            :extended_data,
            user.extended_data.to_h.merge(FINAL_NOTICE_SENT_AT_KEY => Time.current.utc.iso8601)
          )
        end

        # Never under a live link: the citizen who pressed "send again" on
        # day 6 keeps a working link and is deleted only after it has died.
        def delete_stub!(user, counts, dry_run:)
          if live_verify_link?(user)
            counts[:skipped_live_link] += 1
            return
          end
          if dry_run
            counts[:deleted] += 1
            return
          end
          case DestroyStub.call(user)
          when :destroyed then counts[:deleted] += 1
          when :refused then counts[:refused] += 1
          end
        end

        def live_verify_link?(user)
          Decidim::Bih::LoginToken.where(user:, purpose: "verify", consumed_at: nil)
                                  .exists?(expires_at: Time.current..)
        end

        # Every account in +organization+ that still has a pending `sms` row,
        # oldest first. Callers apply #stub? per row; this is only the cheap
        # SQL pre-filter.
        def pending_scope(organization)
          Decidim::User
            .where(organization:, deleted_at: nil)
            .where(id: Decidim::Authorization.where(name: "sms", granted_at: nil).select(:decidim_user_id))
            .order(:id)
        end

        # Anything that makes an account somebody's standing identity rather
        # than a registration half-finished days ago. The same list
        # RegisterWithPhone refuses to adopt, for the same reason.
        def privileged?(user)
          user.admin? || user.roles.present? || user.officialized_at.present? ||
            user.managed? || user.blocked? || user.deleted?
        end

        # find_by, never Ledger#account_for, which would create the row it is
        # asked about.
        def goodwill_account_for(user)
          Decidim::Bih::Goodwill::Account.find_by(
            organization: user.organization,
            owner_type: user.class.base_class.name,
            owner_id: user.id
          )
        end

        # Points are only ever paid to a granted phone, so this can only fire
        # on a row the checks above already refused — it is here because
        # "nothing was earned" is the property being asserted.
        def goodwill_earned?(user)
          account = goodwill_account_for(user)
          return false if account.blank?

          account.balance.to_i.positive? || account.contribution_score.to_i.positive?
        end
      end
    end
  end
end
