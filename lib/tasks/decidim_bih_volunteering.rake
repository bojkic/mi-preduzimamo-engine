# frozen_string_literal: true

namespace :decidim_bih do
  namespace :volunteering do
    desc "Close due undecided volunteer applications for HOST"
    task close_due: :environment do
      organization = Decidim::Organization.find_by(host: ENV.fetch("HOST"))
      abort "Unknown HOST" unless organization

      count = Decidim::Bih::SweepVolunteerApplications.call(organization:)
      puts "closed=#{count}"
    end

    desc "Preview/apply first review marking for legacy automatic volunteer seats (HOST, ACTOR_USER_ID, APPLY=1)"
    task reconcile_legacy: :environment do
      organization = Decidim::Organization.find_by(host: ENV.fetch("HOST"))
      abort "Unknown HOST" unless organization

      before = Decidim::Bih::ReconcileLegacyVolunteerApplications.preview(organization:)
      puts "before candidates=#{before.candidates} going=#{before.going} waitlisted=#{before.waitlisted} " \
           "historical_attendance=#{before.historical_attendance} already_pending_legacy=#{before.already_pending_legacy}"
      unless ENV["APPLY"] == "1"
        puts "Preview only; set APPLY=1 and ACTOR_USER_ID to record legacy first-review state."
        next
      end

      actor = Decidim::User.find_by(id: ENV.fetch("ACTOR_USER_ID"), organization:)
      abort "Actor not found in HOST" unless actor
      converted = Decidim::Bih::ReconcileLegacyVolunteerApplications.apply!(organization:, actor:)
      after = Decidim::Bih::ReconcileLegacyVolunteerApplications.preview(organization:)
      puts "converted=#{converted} remaining_candidates=#{after.candidates} pending_legacy=#{after.already_pending_legacy}"
    end
  end
end
