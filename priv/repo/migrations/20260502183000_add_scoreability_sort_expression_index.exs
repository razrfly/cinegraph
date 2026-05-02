defmodule Cinegraph.Repo.Migrations.AddScoreabilitySortExpressionIndex do
  @moduledoc """
  Adds the Phase 5 scoreability sort expression index.

  Plain CineGraph score sorting ranks only 2+ lens movies by the Phase 4
  confidence-adjusted sort score. The predicate and expression mirror the
  product scoreability rule while keeping the view as a read/display contract.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @lens_count """
  (
    (COALESCE(mob_score, 0) > 0)::int +
    (COALESCE(critics_score, 0) > 0)::int +
    (COALESCE(festival_recognition_score, 0) > 0)::int +
    (COALESCE(time_machine_score, 0) > 0)::int +
    (COALESCE(auteurs_score, 0) > 0)::int +
    (COALESCE(box_office_score, 0) > 0)::int
  )
  """

  def up do
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_score_caches_scoreability_sort_desc
    ON movie_score_caches (
      (overall_score * (#{@lens_count}::double precision / 6.0)) DESC NULLS LAST,
      movie_id
    )
    INCLUDE (
      overall_score,
      mob_score,
      critics_score,
      festival_recognition_score,
      time_machine_score,
      auteurs_score,
      box_office_score
    )
    WHERE overall_score IS NOT NULL
      AND #{@lens_count} >= 2
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_score_caches_scoreability_sort_desc"
  end
end
