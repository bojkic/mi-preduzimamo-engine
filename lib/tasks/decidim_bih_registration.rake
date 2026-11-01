# frozen_string_literal: true

namespace :decidim_bih do
  namespace :registration do
    # R-D8: /dobrodosli is not retroactive. Run this ONCE per organization at
    # the release that ships the welcome page, so citizens who verified before
    # it are not greeted with "your account is confirmed" weeks later. Safe to
    # re-run: only citizens without the stamp are touched.
    #
    # Prints counts only — never a name, an e-mail, a phone or an id.
    desc "Mark already verified citizens as welcomed (idempotent). " \
         "Usage: rake \"decidim_bih:registration:backfill_welcomed[org.host.com]\""
    task :backfill_welcomed, [:org_host] => :environment do |_task, args|
      organization = Decidim::Organization.find_by(host: args[:org_host])
      abort "Organization not found for host: #{args[:org_host]}" unless organization

      counts = Decidim::Bih::Onboarding::Welcome.backfill!(organization)
      scanned = counts.fetch(:scanned)
      stamped = counts.fetch(:stamped)

      puts "Verified citizens with a komšiluk: #{scanned}. Stamped now: #{stamped}. " \
           "Already welcomed: #{scanned - stamped}."
    end

    namespace :pending do
      # Spec: docs/superpowers/specs/2026-09-10-pending-registration-lifecycle-design.md
      # (host repo). Counts only — never a name, an e-mail, a phone or a token.
      desc "Remind (day 5) and delete (day 7) unconfirmed one-step registrations. " \
           "Dry-run unless APPLY=1. Usage: rake \"decidim_bih:registration:pending:sweep[org.host.com]\""
      task :sweep, [:org_host] => :environment do |_task, args|
        organization = Decidim::Organization.find_by(host: args[:org_host])
        abort "Organization not found for host: #{args[:org_host]}" unless organization

        counts = Decidim::Bih::Registration::PendingLifecycle.sweep(
          organization:, dry_run: ENV["APPLY"] != "1"
        )
        puts "organization=#{organization.id} host=#{organization.host}"
        counts.each { |key, value| puts "#{key}=#{value}" }
        puts "No changes were made. Set APPLY=1 to apply." if counts[:dry_run]
        abort "#{counts[:failed]} account(s) failed; see the Rails log" if counts[:failed].positive?
      end

      desc "Re-send the verification (resume e-mail + SMS link and code) to pending citizens. " \
           "Usage: rake \"decidim_bih:registration:pending:resend[org.host.com,122 123]\" (ids space-separated)"
      task :resend, [:org_host, :user_ids] => :environment do |_task, args|
        organization = Decidim::Organization.find_by(host: args[:org_host])
        abort "Organization not found for host: #{args[:org_host]}" unless organization
        ids = args[:user_ids].to_s.split(/[\s,]+/).map(&:to_i).reject(&:zero?)
        abort "Give at least one user id" if ids.empty?

        ids.each do |id|
          user = Decidim::User.find_by(id:, organization:, deleted_at: nil)
          next puts("user #{id}: not found") unless user

          result = Decidim::Bih::Registration::ResendVerification.call(user, actor: nil, source: "rake")
          puts "user #{id}: #{result.status} (email=#{result.email} sms=#{result.sms})"
        end
      end
    end
  end
end
