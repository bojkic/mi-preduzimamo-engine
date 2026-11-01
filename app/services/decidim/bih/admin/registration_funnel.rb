# frozen_string_literal: true

require "json"

module Decidim
  module Bih
    module Admin
      class RegistrationFunnel
        def initialize(organization:, now: Time.current)
          @organization = organization
          @now = now
        end

        def call
          zone = ActiveSupport::TimeZone[Race::Config::TIME_ZONE]
          first_day = @now.in_time_zone(zone).to_date - 29
          sql = ActiveRecord::Base.sanitize_sql_array([SQL, {
                                                        organization_id: @organization.id, now: @now,
                                                        since: zone.local(first_day.year, first_day.month, first_day.day)
                                                      }])
          raw = ActiveRecord::Base.connection.select_value(sql)
          data = raw.is_a?(String) ? JSON.parse(raw) : raw
          days = data.fetch("daily").index_by { |row| row.fetch("day") }
          data["daily"] = (first_day..@now.in_time_zone(zone).to_date).map do |day|
            days.fetch(day.iso8601, { "day" => day.iso8601, "created" => 0, "verified" => 0, "komsiluk" => 0 })
          end
          data
        end

        SQL = <<~SQL.squish
          WITH citizens AS (
            SELECT u.created_at, a.granted_at, p.assigned_at, p.komsiluk_id
            FROM decidim_users u
            LEFT JOIN LATERAL (
              SELECT MIN(granted_at) AS granted_at FROM decidim_authorizations
              WHERE decidim_user_id = u.id AND name = 'sms' AND granted_at IS NOT NULL
            ) a ON TRUE
            LEFT JOIN decidim_bih_citizen_profiles p
              ON p.decidim_user_id = u.id AND p.decidim_organization_id = u.decidim_organization_id
            WHERE u.decidim_organization_id = :organization_id AND u.type = 'Decidim::User'
              AND u.admin = FALSE AND u.managed = FALSE AND u.deleted_at IS NULL
          ), events AS (
            SELECT created_at AS at, 'created' AS stage FROM citizens
            UNION ALL SELECT granted_at, 'verified' FROM citizens WHERE granted_at IS NOT NULL
            UNION ALL SELECT GREATEST(granted_at, assigned_at), 'komsiluk' FROM citizens WHERE komsiluk_id IS NOT NULL AND granted_at IS NOT NULL
          ), days AS (
            SELECT DATE(at AT TIME ZONE 'UTC' AT TIME ZONE 'Europe/Sarajevo') AS day,
              COUNT(*) FILTER (WHERE stage = 'created') AS created,
              COUNT(*) FILTER (WHERE stage = 'verified') AS verified,
              COUNT(*) FILTER (WHERE stage = 'komsiluk') AS komsiluk
            FROM events WHERE at >= :since AND at <= :now GROUP BY day
          )
          SELECT json_build_object(
            'daily', COALESCE((SELECT json_agg(days ORDER BY day) FROM days), '[]'::json),
            'waiting', (SELECT json_build_object(
              'under_hour', COUNT(*) FILTER (WHERE granted_at > CAST(:now AS timestamp) - INTERVAL '1 hour'),
              'under_day', COUNT(*) FILTER (WHERE granted_at <= CAST(:now AS timestamp) - INTERVAL '1 hour' AND granted_at > CAST(:now AS timestamp) - INTERVAL '1 day'),
              'under_week', COUNT(*) FILTER (WHERE granted_at <= CAST(:now AS timestamp) - INTERVAL '1 day' AND granted_at > CAST(:now AS timestamp) - INTERVAL '7 days'),
              'over_week', COUNT(*) FILTER (WHERE granted_at <= CAST(:now AS timestamp) - INTERVAL '7 days')
            ) FROM citizens WHERE granted_at IS NOT NULL AND granted_at <= :now AND komsiluk_id IS NULL)
          )
        SQL
      end
    end
  end
end
