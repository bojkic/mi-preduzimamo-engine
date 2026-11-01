# frozen_string_literal: true

namespace :decidim_bih do
  namespace :postal do
    desc "Purge PENDING (never-granted) postal_letter authorizations older than 6 months " \
         "(dry-run unless APPLY=1). Set ORGANIZATION_ID or HOST to select the org."
    task purge_unconfirmed: :environment do
      organization = find_postal_organization
      abort "Set ORGANIZATION_ID or HOST" unless organization

      cutoff = if ENV["POSTAL_CUTOFF"].present?
                 Time.zone.parse(ENV["POSTAL_CUTOFF"])
               else
                 6.months.ago
               end

      result = Decidim::Bih::Postal::PostalPurgeService.call(
        organization: organization,
        cutoff: cutoff,
        dry_run: ENV["APPLY"] != "1"
      )

      puts "organization=#{organization.id} host=#{organization.host}"
      puts "dry_run=#{result.dry_run} apply=#{ENV["APPLY"] == "1"}"
      puts "cutoff=#{cutoff.iso8601}"
      puts "purged_pending_postal_authorizations=#{result.purged_count}"
      puts "No changes were made. Set APPLY=1 to run with the same cutoffs." if result.dry_run
    end

    # The printed letter's letterhead. Without these the letter still prints —
    # it just falls back to the organisation name and omits the place and the
    # contact line, rather than inventing a return address.
    # window_side is "right" (default) or "left" — which side of the sheet the
    # recipient block sits on, so it lines up with the window in the envelopes
    # actually being used. city_line is appended to addresses that carry no
    # postcode, so a street-only address still reaches a settlement.
    LETTERHEAD_KEYS = %w(
      sender_line place contact_line city_line window_side window_left_mm window_top_mm
    ).freeze
    WINDOW_SIDES = %w(left right).freeze

    desc "Show the letterhead printed on postal letters (Setting namespace \"postal\"). Select the org with HOST or ORGANIZATION_ID."
    task letterhead: :environment do
      organization = find_postal_organization
      abort "Set ORGANIZATION_ID or HOST" unless organization

      values = Decidim::Bih::Setting.namespace_for(organization, "postal")
      puts "organization=#{organization.id} host=#{organization.host}"
      LETTERHEAD_KEYS.each do |key|
        puts "#{key}=#{values[key].presence || "(unset)"}"
      end
    end

    desc "Set one letterhead value: rake decidim_bih:postal:set_letterhead[HOST,KEY,VALUE]. " \
         "KEY is sender_line, place or contact_line; an empty VALUE clears it."
    task :set_letterhead, [:host, :key, :value] => :environment do |_t, args|
      organization = Decidim::Organization.find_by(host: args[:host])
      abort "No organization for host=#{args[:host].inspect}" unless organization

      key = args[:key].to_s
      abort "KEY must be one of #{LETTERHEAD_KEYS.join(", ")}" unless LETTERHEAD_KEYS.include?(key)

      bad_side = key == "window_side" && args[:value].present? && WINDOW_SIDES.exclude?(args[:value].to_s)
      abort "window_side must be one of #{WINDOW_SIDES.join(", ")}" if bad_side

      written = Decidim::Bih::Setting.put(organization, "postal", key, args[:value])
      puts "organization=#{organization.id} host=#{organization.host}"
      puts written.nil? ? "#{key} cleared (letter falls back to the default)" : "#{key}=#{written}"
    end
  end
end

def find_postal_organization
  if ENV["ORGANIZATION_ID"].present?
    Decidim::Organization.find_by(id: ENV["ORGANIZATION_ID"])
  elsif ENV["HOST"].present?
    Decidim::Organization.find_by(host: ENV["HOST"])
  end
end
