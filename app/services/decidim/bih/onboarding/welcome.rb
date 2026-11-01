# frozen_string_literal: true

module Decidim
  module Bih
    module Onboarding
      # "Has this citizen already been welcomed at /dobrodosli?" — the single
      # owner of the mi_welcomed_at flag on Decidim::User#extended_data.
      #
      # Reading is side-effect free because Onboarding::NextStep asks from
      # GET-time redirects. Writing happens in exactly two places: the
      # WelcomeController's POST ("Krenimo"), and the one-off backfill below.
      # Nothing else may set the key — a second writer would silently skip the
      # welcome page for whoever it touched first.
      #
      # The value is an ISO-8601 UTC timestamp rather than a boolean so the
      # flag doubles as "when did this citizen finish onboarding", which is
      # what the backfill needs to be distinguishable later.
      module Welcome
        KEY = "mi_welcomed_at"

        module_function

        def welcomed?(user)
          return false unless user.is_a?(Decidim::User)

          user.extended_data.to_h[KEY].present?
        end

        # Idempotent. Returns true only when THIS call wrote the stamp, so the
        # backfill can count real writes instead of rows scanned.
        #
        # update_column (not update!) for the same reason as
        # Decidim::Bih::EmailConfirmation#mark_confirmed!: a Decidim::User
        # carries validations (tos_agreement, password confirmation) that an
        # unrelated flag write must not have to satisfy, and touching
        # updated_at on every welcome would be noise.
        def mark!(user)
          return false unless user.is_a?(Decidim::User)
          return false if welcomed?(user)

          # extended_data has two writers now (Decidim::Bih::EmailConfirmation's
          # mi_email_confirmed and this key), and the copy in memory can be
          # minutes old — the citizen sat on the page. Reload immediately before
          # the merge so it starts from the row as it is: without this, a
          # confirmation stored while the page was open would be merged away.
          # The re-check is the same reload's second job — a concurrent stamp
          # must not be overwritten with a later timestamp.
          user.reload
          return false if welcomed?(user)

          payload = user.extended_data.to_h.merge(KEY => Time.current.utc.iso8601)
          user.update_column(:extended_data, payload) # rubocop:disable Rails/SkipsModelValidations
          true
        end

        # R-D8: /dobrodosli is NOT retroactive. Citizens who verified before it
        # shipped are stamped once by
        # `rake decidim_bih:registration:backfill_welcomed[HOST]`, so they are
        # not greeted with a "your account is confirmed" page weeks into their
        # membership. Only citizens who have finished the whole chain (granted
        # sms authorization + a picked komšiluk — exactly what NextStep checks
        # before it answers "dobrodosli") are stamped; anyone mid-chain still
        # gets the page when they finish.
        #
        # Returns counts only. Never log or print who was stamped.
        def backfill!(organization)
          scanned = 0
          stamped = 0

          verified_citizens(organization).find_each do |user|
            scanned += 1
            stamped += 1 if mark!(user)
          end

          { scanned:, stamped: }
        end

        def verified_citizens(organization)
          Decidim::User
            .where(organization:, deleted_at: nil, blocked: false)
            .where(id: Decidim::Authorization.where(name: "sms").where.not(granted_at: nil).select(:decidim_user_id))
            .where(id: assigned_komsiluk_user_ids(organization))
        end

        def assigned_komsiluk_user_ids(organization)
          Decidim::Bih::CitizenProfile
            .where(decidim_organization_id: organization.id)
            .where.not(komsiluk_id: nil)
            .select(:decidim_user_id)
        end

        # Internals of #backfill!: the public surface of this module is
        # welcomed? / mark! / backfill!.
        private_class_method :verified_citizens, :assigned_komsiluk_user_ids
      end
    end
  end
end
