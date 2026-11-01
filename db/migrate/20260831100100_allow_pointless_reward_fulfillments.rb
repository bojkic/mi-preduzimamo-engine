# frozen_string_literal: true

# Nagrada sa deducts_points = false nema ledger transakciju, pa veza mora
# postati opciona. Jedinstveni indeks ostaje netaknut — Postgres dozvoljava
# više NULL vrijednosti u jedinstvenom indeksu, pa se nijedno postojeće
# jemstvo ne gubi.
class AllowPointlessRewardFulfillments < ActiveRecord::Migration[7.2]
  def up
    change_column_null :decidim_bih_goodwill_reward_fulfillments,
                       :decidim_bih_goodwill_transaction_id, true
  end

  def down
    # Povratak NIJE moguć bez gubitka podataka čim postoji makar jedan red bez
    # transakcije (automatski izdata pozivnica: ulazni kod, rok za potvrdu,
    # trag prisustva). Umjesto da ih tiho obrišemo, odbijamo rollback i
    # kažemo operateru tačno koliko redova blokira povratak i šta prvo mora
    # riješiti — brisanje bez pitanja bilo bi upravo ona zamka tihog gubitka
    # podataka koju ova migracija namjerno izbjegava.
    blocking_count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM decidim_bih_goodwill_reward_fulfillments
      WHERE decidim_bih_goodwill_transaction_id IS NULL
    SQL

    if blocking_count.positive?
      raise ActiveRecord::IrreversibleMigration,
            "#{blocking_count} ispunjenja nagrade nema ledger transakciju (automatski " \
            "izdate pozivnice). Vracanje bi ih nepovratno obrisalo — odluci sta s njima " \
            "prije nego sto pokrenes rollback."
    end

    change_column_null :decidim_bih_goodwill_reward_fulfillments,
                       :decidim_bih_goodwill_transaction_id, false
  end
end
