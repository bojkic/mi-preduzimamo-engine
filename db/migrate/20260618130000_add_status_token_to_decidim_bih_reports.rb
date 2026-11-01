# frozen_string_literal: true

require "securerandom"

# Adds an unguessable per-report token for reporter-owned status links. The
# existing BR-YYYY-NNNN reference route remains public and PII-light; this token
# is the safe path to use before any private reporter/detail surface expands.
class AddStatusTokenToDecidimBihReports < ActiveRecord::Migration[7.2]
  def up
    add_status_token_column
    backfill_status_tokens
    change_column_null :decidim_bih_reports, :status_token, false
    add_status_token_index
  end

  def down
    remove_index :decidim_bih_reports, name: "idx_bih_reports_org_status_token" if index_exists?(
      :decidim_bih_reports,
      [:decidim_organization_id, :status_token],
      name: "idx_bih_reports_org_status_token"
    )
    remove_column :decidim_bih_reports, :status_token if column_exists?(:decidim_bih_reports, :status_token)
  end

  private

  def add_status_token_column
    return if column_exists?(:decidim_bih_reports, :status_token)

    add_column :decidim_bih_reports, :status_token, :string
  end

  def add_status_token_index
    return if index_exists?(
      :decidim_bih_reports,
      [:decidim_organization_id, :status_token],
      name: "idx_bih_reports_org_status_token"
    )

    add_index :decidim_bih_reports,
              [:decidim_organization_id, :status_token],
              unique: true,
              name: "idx_bih_reports_org_status_token"
  end

  def backfill_status_tokens
    loop do
      row = select_one(<<~SQL.squish)
        SELECT id, decidim_organization_id
        FROM decidim_bih_reports
        WHERE status_token IS NULL OR status_token = ''
        LIMIT 1
      SQL
      break unless row

      org_id = Integer(row.fetch("decidim_organization_id"))
      token = unique_status_token_for(org_id)
      execute(<<~SQL.squish)
        UPDATE decidim_bih_reports
        SET status_token = #{connection.quote(token)}
        WHERE id = #{Integer(row.fetch("id"))}
      SQL
    end
  end

  def unique_status_token_for(org_id)
    loop do
      token = SecureRandom.urlsafe_base64(24)
      exists = select_value(<<~SQL.squish)
        SELECT 1
        FROM decidim_bih_reports
        WHERE decidim_organization_id = #{org_id}
          AND status_token = #{connection.quote(token)}
        LIMIT 1
      SQL
      return token unless exists
    end
  end
end
