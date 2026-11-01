# frozen_string_literal: true

# One-time compatibility backfill from Decidim 0.31 user groups into the new
# first-class organization profile model. Existing groups are marked verified so
# current public Goodwill organization pages do not disappear after migration.
class BackfillPartnerProfilesFromUserGroups < ActiveRecord::Migration[7.2]
  class User < ActiveRecord::Base
    self.table_name = "decidim_users"
    self.inheritance_column = :_type_disabled
  end

  class GroupMembership < ActiveRecord::Base
    self.table_name = "decidim_user_group_memberships"
  end

  class PartnerProfile < ActiveRecord::Base
    self.table_name = "decidim_bih_partner_profiles"
  end

  class PartnerMembership < ActiveRecord::Base
    self.table_name = "decidim_bih_partner_memberships"
  end

  ROLE_MAP = {
    "creator" => "owner",
    "admin" => "manager",
    "member" => "member",
    "requested" => "member"
  }.freeze

  def up
    return unless table_exists?(:decidim_user_group_memberships)

    User.where("extended_data @> ?", { group: true }.to_json).find_each do |group|
      profile = PartnerProfile.find_or_initialize_by(
        decidim_organization_id: group.decidim_organization_id,
        legacy_user_group_id: group.id
      )
      profile.assign_attributes(
        display_name: group.name.presence || group.nickname.presence || "Organizacija ##{group.id}",
        legal_name: group.name.presence,
        slug: unique_slug_for(group, profile),
        kind: "informal_group",
        verification_status: "verified",
        verified_at: group.created_at,
        public_description: group.about.presence,
        website: group.personal_url.presence,
        created_at: profile.created_at || Time.current,
        updated_at: Time.current
      )
      profile.save!

      GroupMembership.where(decidim_user_group_id: group.id).find_each do |membership|
        status = membership.role == "requested" ? "pending" : "accepted"
        PartnerMembership.find_or_create_by!(
          decidim_organization_id: group.decidim_organization_id,
          partner_profile_id: profile.id,
          decidim_user_id: membership.decidim_user_id
        ) do |partner_membership|
          partner_membership.role = ROLE_MAP.fetch(membership.role.to_s, "member")
          partner_membership.status = status
          partner_membership.accepted_at = membership.created_at if status == "accepted"
          partner_membership.created_at = membership.created_at
          partner_membership.updated_at = Time.current
        end
      end
    end
  end

  def down
    legacy_profile_ids = PartnerProfile.where.not(legacy_user_group_id: nil).pluck(:id)
    PartnerMembership.where(partner_profile_id: legacy_profile_ids).delete_all
    PartnerProfile.where(id: legacy_profile_ids).delete_all
  end

  private

  def unique_slug_for(group, profile)
    return profile.slug if profile.slug.present?

    base = group.nickname.presence || group.name.presence || "organizacija-#{group.id}"
    slug = base.to_s.parameterize.presence || "organizacija-#{group.id}"
    candidate = slug
    suffix = 2

    while PartnerProfile
          .where(decidim_organization_id: group.decidim_organization_id, slug: candidate)
          .where.not(id: profile.id)
          .exists?
      candidate = "#{slug}-#{suffix}"
      suffix += 1
    end

    candidate
  end
end
