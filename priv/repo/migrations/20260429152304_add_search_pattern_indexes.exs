defmodule Cinegraph.Repo.Migrations.AddSearchPatternIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Case-insensitive prefix indexes (varchar_pattern_ops) for the typeahead
  # prefix path in Cinegraph.Search.global/2.
  #
  # movies.title already has idx_movies_lower_title_pattern (migration
  # 20251226152910). people.name had a similar one but it was dropped;
  # restore it. production_companies.name has only a plain btree which
  # doesn't help case-insensitive prefix.

  def up do
    execute """
    CREATE INDEX CONCURRENTLY people_name_lower_pattern_idx
    ON people (lower(name) varchar_pattern_ops)
    """

    execute """
    CREATE INDEX CONCURRENTLY production_companies_name_lower_pattern_idx
    ON production_companies (lower(name) varchar_pattern_ops)
    """

    # CREATE INDEX CONCURRENTLY does not auto-analyze, so the planner can
    # ignore the new index until autovacuum catches up. Force fresh stats.
    execute "ANALYZE people"
    execute "ANALYZE production_companies"
  end

  def down do
    execute "DROP INDEX CONCURRENTLY production_companies_name_lower_pattern_idx"
    execute "DROP INDEX CONCURRENTLY people_name_lower_pattern_idx"
  end
end
