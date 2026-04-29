defmodule Cinegraph.Repo.Migrations.AddSearchTrigramIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # GIN trigram indexes powering Cinegraph.Search.global/2 fuzzy fallback.
  # pg_trgm extension is already enabled (see 20260125130941_enable_pg_trgm_extension.exs).

  def up do
    execute """
    CREATE INDEX CONCURRENTLY movies_title_trgm_idx
    ON movies USING gin (title gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY movies_original_title_trgm_idx
    ON movies USING gin (original_title gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY people_name_trgm_idx
    ON people USING gin (name gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY movie_lists_name_trgm_idx
    ON movie_lists USING gin (name gin_trgm_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY production_companies_name_trgm_idx
    ON production_companies USING gin (name gin_trgm_ops)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY production_companies_name_trgm_idx"
    execute "DROP INDEX CONCURRENTLY movie_lists_name_trgm_idx"
    execute "DROP INDEX CONCURRENTLY people_name_trgm_idx"
    execute "DROP INDEX CONCURRENTLY movies_original_title_trgm_idx"
    execute "DROP INDEX CONCURRENTLY movies_title_trgm_idx"
  end
end
