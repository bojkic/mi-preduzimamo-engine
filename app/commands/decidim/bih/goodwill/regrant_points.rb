# frozen_string_literal: true

module Decidim
  module Bih
    module Goodwill
      # Re-grants wallet points an organization received as gifts to one of
      # its members — an organization admin paying forward goodwill to a
      # volunteer. Wallet-guarded (no overdraw); recognition is untouched
      # (regrants aren't earns, so a leaderboard rank is never moved).
      #
      # AUTHORIZATION: the actor must be an admin (creator/admin) of the group,
      # and the recipient must be an active member of that same group.
      #
      # Broadcasts :ok(member, amount) / :forbidden (actor not a group admin) /
      # :invalid (bad group/member/amount) / :insufficient (group wallet short).
      class RegrantPoints < Decidim::Command
        CATEGORIES = %w(
          member_grant
          volunteer_grant
          attendance
          setup
          cleanup
          speaker_mentor
          logistics
          reporting
          mentoring
          thank_you
        ).freeze
        MEMBER_REQUIRED_CATEGORIES = %w(member_grant volunteer_grant).freeze

        def initialize(actor, partner_profile_id, member_id, amount, options = {})
          @actor = actor
          @partner_profile_id = partner_profile_id
          @member_id = member_id
          @recipient_lookup = options[:recipient_lookup].to_s.strip
          @category = options.fetch(:category, "member_grant").to_s.presence_in(CATEGORIES) || "member_grant"
          # Coerce defensively: a crafted `amount[]=1` makes params[:amount] an
          # Array, and Array#to_i would raise. `.to_s.to_i` yields 0 (-> :invalid).
          @amount = amount
          @request_key = options.fetch(:request_key) { SecureRandom.uuid }
        end

        def call
          return broadcast(:invalid) unless @actor.present?
          @amount = RequestIdentity.amount(@amount)
          key = RequestIdentity.key("regrant", @actor, @request_key)

          profile = Decidim::Bih::PartnerProfile
                    .goodwill_eligible
                    .where(organization: @actor.organization)
                    .find_by(id: @partner_profile_id)
          return broadcast(:invalid) if profile.nil?

          return broadcast(:forbidden) unless profile_manager?(@actor, profile)

          member = recipient
          return broadcast(:invalid) unless valid_recipient?(member, profile)

          owner = PartnerOwner.owner_for(profile)
          Ledger.new.transfer(
            from_owner: owner, to_owner: member, amount: @amount,
            kind: "regrant", reason: "organization_grant", idempotency_key: key,
            metadata: {
              member_id: member.id,
              partner_profile_id: profile.id,
              grant_category: @category,
              member_required: member_required?
            }
          )
          broadcast(:ok, member, @amount)
        rescue Decidim::Bih::Goodwill::InsufficientBalanceError
          broadcast(:insufficient)
        rescue ArgumentError
          broadcast(:invalid)
        end

        private

        def valid_actor_and_amount?
          @actor.present? && @amount.positive?
        end

        def profile_manager?(user, profile)
          profile.memberships.accepted.exists?(
            decidim_user_id: user.id,
            role: Decidim::Bih::PartnerMembership::FINANCE_ROLES
          )
        end

        def profile_member?(user, profile)
          profile.memberships.accepted.exists?(decidim_user_id: user.id)
        end

        def valid_recipient?(member, profile)
          return false if member.nil?
          return false if member_required? && !profile_member?(member, profile)

          # No regrant-to-self: blocks the self-gift -> self-regrant laundering
          # loop (move your points into your own group then back to yourself).
          member.id != @actor.id
        end

        def member_required?
          MEMBER_REQUIRED_CATEGORIES.include?(@category)
        end

        def recipient
          if @member_id.present?
            Decidim::User.not_user_group
                         .where(organization: @actor.organization)
                         .find_by(id: @member_id)
          else
            recipient_by_lookup
          end
        end

        def recipient_by_lookup
          return nil if @recipient_lookup.blank?

          normalized = @recipient_lookup.delete_prefix("@").downcase
          Decidim::User
            .not_user_group
            .where(organization: @actor.organization, deleted_at: nil)
            .where("LOWER(email) = :lookup OR LOWER(nickname) = :lookup", lookup: normalized)
            .first
        end
      end
    end
  end
end
