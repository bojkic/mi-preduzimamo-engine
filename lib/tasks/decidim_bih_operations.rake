# frozen_string_literal: true

require "digest"

namespace :decidim_bih do
  namespace :operations do
    desc "Send a deduplicated PII-free health alert from structured smoke output"
    task health_alert: :environment do
      host = ENV["HOST"].to_s.strip
      input_path = ENV["OPS_HEALTH_ALERT_FILE"].to_s.strip
      abort "HOST is required" if host.blank?
      abort "OPS_HEALTH_ALERT_FILE is required" if input_path.blank?

      organization = Decidim::Organization.find_by(host:)
      abort "Organization not found for host: #{host}" unless organization

      rows = File.foreach(input_path).filter_map do |line|
        fields = line.chomp.split("\t", 5)
        next unless fields.size >= 4 && %w[warn fail].include?(fields[3])

        fields.first(4).map { |value| Decidim::Bih::SafeErrorMetadata.sanitize_text(value, max: 120) }
      end.first(50)
      if rows.empty?
        puts "operations_health_alert skipped=no_warning_rows"
        next
      end

      settings_recipient = Decidim::Bih::Setting.namespace_for(organization, "operations")["operator_email"].presence
      global_recipient = ENV["BIH_OPS_ALERT_ENABLED"] == "1" ? ENV["BIH_OPS_ALERT_EMAIL"].presence : nil
      recipient = settings_recipient || global_recipient
      unless recipient
        puts "operations_health_alert skipped=no_opt_in_recipient warnings=#{rows.size}"
        next
      end

      digest = Digest::SHA256.hexdigest(rows.flatten.join("\0"))
      cache_key = "bih:ops_health_alert:#{organization.id}:#{digest}"
      if Rails.cache.exist?(cache_key)
        puts "operations_health_alert skipped=duplicate warnings=#{rows.size}"
        next
      end

      Decidim::Bih::Admin::OpsHealthAlertMailer.alert(
        organization:,
        recipient:,
        rows:
      ).deliver_now
      Rails.cache.write(cache_key, true, expires_in: 6.hours)
      puts "operations_health_alert sent warnings=#{rows.size}"
    end
  end
end
