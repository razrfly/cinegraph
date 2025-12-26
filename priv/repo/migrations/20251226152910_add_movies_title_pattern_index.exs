defmodule Cinegraph.Repo.Migrations.AddMoviesTitlePatternIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Pattern ops index for case-insensitive prefix searches
    # Supports: WHERE lower(title) LIKE 'prefix%'
    execute """
    CREATE INDEX CONCURRENTLY idx_movies_lower_title_pattern
    ON movies (lower(title) varchar_pattern_ops)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY idx_movies_lower_title_pattern"
  end
end
