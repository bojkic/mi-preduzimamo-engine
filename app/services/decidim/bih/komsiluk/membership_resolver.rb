# frozen_string_literal: true

require_relative "../notification_preferences"

module Decidim
  module Bih
    module Komsiluk
      # Single source of truth for "who should receive a Komšiluk / MZ fan-out".
      #
      # Both the operator broadcast (KomsilukBroadcast) and the urgent-post bell
      # (KomsilukPostNotificationService) need the SAME audience query, layered
      # with the SAME privacy posture:
      #
      #   1. org-scoping            — only CitizenProfiles of this organization
      #   2. audience selection     — a single komšiluk OR a whole MZ (with the
      #                               komšiluk-overlap union for nil-mz_id residents)
      #   3. active-user filter     — blocked: false, deleted_at: nil, confirmed
      #   4. author exclusion       — optional (exclude_user_id:)
      #   5. per-user opt-out       — optional (honor_opt_out:), driven by
      #                               the requested MI notification topic/channel
      #
      # The class returns ONLY a list of user ids; it never returns or logs the
      # users themselves, keeping the privacy contract (no recipient list leaks)
      # in one place.
      #
      # Audience construction:
      #
      #   # a single komšiluk
      #   MembershipResolver.for_komsiluk(organization:, komsiluk_id:)
      #
      #   # a whole MZ (unions in komšiluci that overlap the MZ but have nil mz_id)
      #   MembershipResolver.for_mz(organization:, mz_area:)
      #
      # then layer the privacy options:
      #
      #   resolver.recipient_ids(exclude_user_id: post.decidim_user_id,
      #                          honor_opt_out: true)
      class MembershipResolver
        # Legacy per-user setting used before MI notification topics/channels
        # were split. It remains a fallback so existing opt-outs keep working.
        OPT_OUT_KEY = NotificationPreferences::LEGACY_LOCAL_ALERTS_KEY

        # Build a resolver scoped to a single komšiluk's assigned citizens.
        #
        # @param organization [Decidim::Organization]
        # @param komsiluk_id  [Integer]
        def self.for_komsiluk(organization:, komsiluk_id:)
          new(organization:, profiles: komsiluk_profiles(organization, komsiluk_id))
        end

        # Build a resolver scoped to an entire MZ's assigned citizens.
        #
        # Uses the denormalised mz_id index for the common case but UNIONS in any
        # citizen whose komšiluk overlaps this MZ (overlapping_mz_slugs) yet whose
        # mz_id is nil because their primary_mz is unresolved — so they are never
        # silently excluded from an MZ-level fan-out.
        #
        # @param organization [Decidim::Organization]
        # @param mz_area      [Decidim::Bih::LocalArea]  kind "mz"
        def self.for_mz(organization:, mz_area:)
          new(organization:, profiles: mz_profiles(organization, mz_area))
        end

        # Internal: assemble the CitizenProfile scope for a single komšiluk.
        def self.komsiluk_profiles(organization, komsiluk_id)
          CitizenProfile.where(
            decidim_organization_id: organization.id,
            komsiluk_id: komsiluk_id
          )
        end
        private_class_method :komsiluk_profiles

        # Internal: assemble the CitizenProfile scope for a whole MZ, including the
        # komšiluk-overlap union for nil-mz_id residents.
        def self.mz_profiles(organization, mz_area)
          scope = CitizenProfile.where(decidim_organization_id: organization.id)

          komsiluk_ids = komsiluk_ids_overlapping_mz(organization, mz_area)
          return scope.where(mz_id: mz_area.id) if komsiluk_ids.empty?

          scope.where(mz_id: mz_area.id).or(scope.where(komsiluk_id: komsiluk_ids))
        end
        private_class_method :mz_profiles

        # Ids of komšiluci whose overlapping_mz_slugs include this MZ's slug.
        def self.komsiluk_ids_overlapping_mz(organization, mz_area)
          LocalArea
            .komsiluci
            .where(decidim_organization_id: organization.id)
            .where("overlapping_mz_slugs @> ?::jsonb", [mz_area.slug].to_json)
            .pluck(:id)
        end
        private_class_method :komsiluk_ids_overlapping_mz

        # @param organization [Decidim::Organization]
        # @param profiles     [ActiveRecord::Relation<CitizenProfile>]  the audience scope
        def initialize(organization:, profiles:)
          @organization = organization
          @profiles = profiles
        end

        # Resolve the unique Decidim user ids for eligible recipients.
        #
        # @param exclude_user_id [Integer, nil]  a user id to omit (e.g. the author)
        # @param honor_opt_out   [Boolean]       when true, drop users whose
        #   topic/channel notification preference is disabled
        # @return [Array<Integer>]
        def recipient_ids(exclude_user_id: nil, honor_opt_out: false,
                          notification_topic: :komsiluk_urgent,
                          notification_channel: :bell,
                          fallback_key: OPT_OUT_KEY)
          profile_user_ids = @profiles.where.not(decidim_user_id: nil).pluck(:decidim_user_id)
          return [] if profile_user_ids.empty?

          users = active_users(profile_user_ids)
          users = users.where.not(id: exclude_user_id) if exclude_user_id.present?

          if honor_opt_out && notification_channel.to_s != "bell"
            users.reject do |user|
              opted_out?(user, notification_topic:, notification_channel:, fallback_key:)
            end.map(&:id)
          else
            users.pluck(:id)
          end
        end

        private

        attr_reader :organization

        # Real, active, confirmed, non-blocked users in this org from the given ids.
        def active_users(user_ids)
          Decidim::User
            .where(organization:, id: user_ids)
            .where(blocked: false, deleted_at: nil)
            .where.not(confirmed_at: nil)
        end

        def opted_out?(user, notification_topic:, notification_channel:, fallback_key:)
          !NotificationPreferences.enabled?(
            user,
            topic: notification_topic,
            channel: notification_channel,
            fallback_key:
          )
        end
      end
    end
  end
end
