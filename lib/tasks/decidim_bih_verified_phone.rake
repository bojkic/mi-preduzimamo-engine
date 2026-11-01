# frozen_string_literal: true

namespace :decidim_bih do
  namespace :verified_phone do
    desc "Read-only contact consistency preview; APPLY=1 requires explicit USER_IDS. Usage: reconcile[org.host]"
    task :reconcile, [:org_host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by!(host: args[:org_host])
      apply = ENV["APPLY"] == "1"
      raw_ids = ENV.fetch("USER_IDS", "").split(/[\s,]+/).reject(&:empty?)
      abort "USER_IDS must contain numeric account IDs" unless raw_ids.all? { |id| id.match?(/\A[1-9][0-9]*\z/) }
      abort "APPLY=1 requires explicit USER_IDS from the preview" if apply && raw_ids.empty?

      users = Decidim::User.where(organization:, deleted_at: nil)
      users = users.where(id: raw_ids) if raw_ids.any?
      users.find_each do |user|
        phone = Decidim::Bih::VerifiedPhone.phone_for(user:, organization:)
        status = if phone.blank?
                   "no_valid_stored_phone"
                 elsif Decidim::Bih::VerifiedPhone.consistent?(user:, organization:)
                   "consistent"
                 elsif apply
                   Decidim::Bih::VerifiedPhone.synchronize!(user:, organization:, phone:) ? "repaired" : "failed"
                 else
                   "repairable"
                 end
        puts "user_id=#{user.id} status=#{status}"
      end
      puts "Read-only preview. No changes made." unless apply
    end
  end
end
