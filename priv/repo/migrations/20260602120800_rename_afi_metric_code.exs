defmodule Cinegraph.Repo.Migrations.RenameAfiMetricCode do
  use Ecto.Migration

  # Issue #1036 Session 2.5: the catalog code/source_type was `afi_top_100`, but the
  # canonical data uses `afi_100` everywhere (movie_lists.source_key, movies.canonical_sources).
  # Align the catalog to the data so the AFI member actually reconciles with the feed.
  # Idempotent: fixes already-seeded rows; fresh DBs get `afi_100` straight from CatalogSeed.
  def up do
    execute("""
    UPDATE metric_definitions
    SET code = 'afi_100', source_type = 'afi_100'
    WHERE code = 'afi_top_100'
    """)
  end

  def down do
    execute("""
    UPDATE metric_definitions
    SET code = 'afi_top_100', source_type = 'afi_top_100'
    WHERE code = 'afi_100'
    """)
  end
end
