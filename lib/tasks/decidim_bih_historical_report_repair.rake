# frozen_string_literal: true
require "json"
namespace :decidim_bih do
  namespace :goodwill do
    desc "Private outcome repair preview/apply: MODE=preview|apply MANIFEST=/private/file REPORT_IDS=... ORGANIZATION_ID=..."
    task historical_report_repair: :environment do
      mode = ENV.fetch("MODE", "preview")
      abort "MODE must be preview or apply" unless %w(preview apply).include?(mode)
      path = File.expand_path(ENV.fetch("MANIFEST"))
      abort "Manifest parent must be a private directory" unless File.directory?(File.dirname(path)) && (File.stat(File.dirname(path)).mode & 0o077).zero?
      organization = Decidim::Organization.find(Integer(ENV.fetch("ORGANIZATION_ID")))
      repair = Decidim::Bih::Goodwill::HistoricalReportRepair.new(organization:)
      if mode == "preview"
        ids = ENV.fetch("REPORT_IDS").split(",")
        manifest = ActiveRecord::Base.transaction(isolation: :repeatable_read) do
          ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY")
          repair.preview(report_ids: ids)
        end
        File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.pretty_generate(manifest)) }
        puts JSON.generate(manifest.fetch("summary").merge(digest: manifest.fetch("digest"), mode: "preview"))
      else
        abort "APPLY=1 is required" unless ENV["APPLY"] == "1"
        abort "Manifest must be private regular file" unless File.file?(path) && !File.symlink?(path) && (File.stat(path).mode & 0o077).zero?
        manifest = JSON.parse(File.read(path))
        actor = Decidim::User.find(Integer(ENV.fetch("ACTOR_ID")))
        expected = { reports: Integer(ENV.fetch("EXPECTED_REPORTS", "17")), users: Integer(ENV.fetch("EXPECTED_USERS", "14")),
                     recognition_delta: Integer(ENV.fetch("EXPECTED_DELTA", "-275")) }
        puts JSON.generate(repair.apply!(manifest:, actor:, expected_digest: ENV.fetch("MANIFEST_SHA256"), expected_summary: expected))
      end
    end
  end
end
