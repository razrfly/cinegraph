defmodule Cinegraph.Repo.Migrations.AddLensSortAndFestivalIndexes do
  @moduledoc """
  Performance indexes for V2 movies discovery (issue #785).

  - btree DESC indexes on `movie_score_caches` lens columns. Without these,
    `ORDER BY <lens_score> DESC LIMIT 24` on the score cache (~50k rows today,
    growing) does a Seq Scan + Sort node. With them, the planner can do an
    Index Scan + LIMIT.
  - composite on `festival_ceremonies(organization_id, year)`. The festival
    nominations subquery joins ceremonies and filters on both columns; a single
    composite covers most query patterns (org-scoped lookups, org+year ranges).

  Uses CONCURRENTLY to avoid blocking writes during deploy. `IF NOT EXISTS`
  guards make the migration safely repeatable.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @lens_columns ~w(
    overall_score
    mob_score
    critics_score
    festival_recognition_score
    time_machine_score
    auteurs_score
  )

  def up do
    for col <- @lens_columns do
      execute """
      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_score_caches_#{col}_desc
      ON movie_score_caches (#{col} DESC NULLS LAST)
      WHERE #{col} IS NOT NULL
      """
    end

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_festival_ceremonies_org_year
    ON festival_ceremonies (organization_id, year)
    """
  end

  def down do
    for col <- @lens_columns do
      execute "DROP INDEX CONCURRENTLY IF EXISTS idx_score_caches_#{col}_desc"
    end

    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_festival_ceremonies_org_year"
  end
end
