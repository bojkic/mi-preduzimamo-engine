# frozen_string_literal: true
module Decidim
  module Bih
    module Race
      # One SQL statement gives every candidate, overflow included, the same MVCC
      # view. No personal contact or report body is stored in this private evidence.
      class SnapshotBuilder
        def initialize(organization:, config: nil, at: Time.current)
          @organization = organization
          @config = config || Config.new(organization:)
          @at = [at, @config.window_to].min
        end

        def call
          sql = ActiveRecord::Base.sanitize_sql_array([SQL, {
            org: @organization.id, edition: Edition::KEY, at: @at,
            from: @config.window_from, to: @config.window_to
          }])
          raw = ActiveRecord::Base.connection.select_value(sql)
          data = raw.is_a?(String) ? JSON.parse(raw) : raw
          data.merge("version" => 1, "edition" => Edition::KEY, "cutoff" => @config.window_to.iso8601,
                     "effective_at" => @at.iso8601, "weights" => @config.weights.stringify_keys,
                     "caps" => @config.caps.stringify_keys)
        end

        SQL = <<~SQL
          WITH people AS (
            SELECT u.id AS user_id, cp.komsiluk_id AS current_area,
              COALESCE(m.komsiluk_id, cp.komsiluk_id) AS area,
              cp.assigned_at AS current_assigned_at,
              COALESCE(m.qualified_at, GREATEST(a.granted_at, COALESCE(m.assigned_at,cp.assigned_at))) AS qualified_at,
              a.granted_at,
              (u.deleted_at IS NULL AND u.blocked = FALSE AND a.granted_at IS NOT NULL
               AND a.granted_at <= :at AND a.granted_at < :to AND COALESCE(m.assigned_at,cp.assigned_at) <= :at AND COALESCE(m.assigned_at,cp.assigned_at) < :to
               AND COALESCE(m.komsiluk_id,cp.komsiluk_id) IS NOT NULL) AS eligible,
              COALESCE(m.provenance, 'current_profile') AS provenance
            FROM decidim_users u
            JOIN decidim_bih_citizen_profiles cp ON cp.decidim_user_id=u.id AND cp.decidim_organization_id=u.decidim_organization_id
            LEFT JOIN decidim_bih_race_editions ed ON ed.decidim_organization_id=u.decidim_organization_id AND ed.key=:edition
            LEFT JOIN decidim_bih_race_memberships m ON m.edition_id=ed.id AND m.decidim_user_id=u.id AND ed.baseline_at IS NOT NULL
            LEFT JOIN LATERAL (SELECT MIN(granted_at) AS granted_at FROM decidim_authorizations
              WHERE decidim_user_id=u.id AND name='sms' AND granted_at IS NOT NULL) a ON true
            WHERE u.decidim_organization_id=:org AND u.type='Decidim::User'
          ), authors AS (
            SELECT DISTINCT ON(coauthorable_id) coauthorable_id AS proposal_id, decidim_author_id AS user_id
            FROM decidim_coauthorships
            WHERE coauthorable_type='Decidim::Proposals::Proposal' AND decidim_author_type='Decidim::UserBaseEntity'
            ORDER BY coauthorable_id,id
          ), items AS (
            SELECT 'registration:'||p.user_id AS key, 'registered' AS kind, p.user_id AS source_id,
              p.user_id, p.area, p.qualified_at AS at,
              (p.eligible AND p.qualified_at>=:from AND p.qualified_at<:to) AS eligible,
              jsonb_build_object('qualified_at',p.qualified_at,'phone_granted_at',p.granted_at,'provenance',p.provenance) AS facts
            FROM people p
            UNION ALL
            SELECT 'report:'||r.id, 'report', r.id, r.decidim_user_id, p.area, r.created_at,
              COALESCE(p.eligible AND r.status<>'odbijeno' AND r.duplicate_of_report_id IS NULL,false),
              jsonb_build_object('status',r.status,'review_state',r.review_state,'anonymous',r.anonymous,
                'duplicate_of',r.duplicate_of_report_id,'qualified_at',p.qualified_at,'updated_at',r.updated_at)
            FROM decidim_bih_reports r LEFT JOIN people p ON p.user_id=r.decidim_user_id
            WHERE r.decidim_organization_id=:org AND r.created_at>=:from AND r.created_at<:to AND r.created_at<=:at
            UNION ALL
            SELECT 'proposal:'||pr.id, 'proposal', pr.id, a.user_id, p.area, pr.published_at,
              COALESCE(p.eligible AND pr.withdrawn_at IS NULL AND pr.deleted_at IS NULL
                AND comp.published_at IS NOT NULL AND mod.hidden_at IS NULL,false),
              jsonb_build_object('published_at',pr.published_at,'withdrawn_at',pr.withdrawn_at,'deleted_at',pr.deleted_at,
                'hidden_at',mod.hidden_at,'component_id',comp.id,'component_published_at',comp.published_at,
                'space_type',comp.participatory_space_type,'space_id',comp.participatory_space_id,'qualified_at',p.qualified_at)
            FROM decidim_proposals_proposals pr JOIN authors a ON a.proposal_id=pr.id
            JOIN decidim_users u ON u.id=a.user_id AND u.decidim_organization_id=:org
            LEFT JOIN people p ON p.user_id=a.user_id
            JOIN decidim_components comp ON comp.id=pr.decidim_component_id
            LEFT JOIN decidim_moderations mod ON mod.decidim_reportable_id=pr.id AND mod.decidim_reportable_type='Decidim::Proposals::Proposal'
            WHERE pr.published_at>=:from AND pr.published_at<:to AND pr.published_at<=:at
          )
          SELECT jsonb_build_object(
            'items',COALESCE((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.key) FROM items i),'[]'::jsonb),
            'areas',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',id,'slug',slug,'zona',zona,'name',name) ORDER BY id)
              FROM decidim_bih_local_areas WHERE decidim_organization_id=:org AND kind='komsiluk'),'[]'::jsonb),
            'electorate',COALESCE((SELECT jsonb_agg(jsonb_build_object('user_id',p.user_id,'area',p.current_area,
              'granted_at',p.granted_at,'assigned_at',p.current_assigned_at) ORDER BY p.user_id)
              FROM people p WHERE p.eligible AND p.current_area IS NOT NULL AND p.current_assigned_at<=:at AND p.current_assigned_at<:to),'[]'::jsonb))
        SQL
      end
    end
  end
end
