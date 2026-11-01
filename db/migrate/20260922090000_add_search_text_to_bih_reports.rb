# frozen_string_literal: true

# Full-text search over the admin report queue.
#
# `search_text` holds the report's own fields PLUS its message bodies, already
# run through Decidim::Bih::ReportSearchText.normalize — Cyrillic folded to
# Latin, diacritics folded away, punctuation turned into token boundaries. The
# normalisation happens in Ruby (it reuses the engine's Transliterator), which
# is why this is a plain text column kept current by model callbacks rather
# than a generated column.
#
# The index is built with the 'simple' text search configuration because
# PostgreSQL ships no Serbian/Bosnian stemmer; inflection is handled by prefix
# queries instead. The expression here must stay character-for-character
# identical to the one in Report.full_text_search or the index is not used.
class AddSearchTextToBihReports < ActiveRecord::Migration[7.2]
  def up
    add_column :decidim_bih_reports, :search_text, :text

    execute <<~SQL.squish
      CREATE INDEX index_decidim_bih_reports_on_search_text
      ON decidim_bih_reports
      USING gin (to_tsvector('simple', coalesce(search_text, '')))
    SQL
  end

  def down
    execute "DROP INDEX IF EXISTS index_decidim_bih_reports_on_search_text"
    remove_column :decidim_bih_reports, :search_text
  end
end
