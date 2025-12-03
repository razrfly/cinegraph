defmodule Cinegraph.Repo.Migrations.FinalIndexOptimizations do
  use Ecto.Migration

  @moduledoc """
  Final index optimizations from PlanetScale analysis.

  Changes:
  1. Remove redundant festival_nominations index (#16)
     - festival_nominations_ceremony_id_category_id_movie_id_index is redundant
     - Covered by festival_nominations_unique_nomination_idx (same columns, but unique)

  2. Add year extraction index on movies (#32)
     - Many queries use EXTRACT(YEAR FROM release_date)
     - Found in: filters.ex, custom_filters.ex, year_imports_live.ex,
       daily_year_import_worker.ex, movie_predictor.ex, collaborations.ex, etc.

  NOT implemented:
  - #31: oban_jobs queue index - Oban's composite index (state, queue, priority,
    scheduled_at, id) already covers queue lookups in standard usage patterns
  """

  def up do
    # ============================================
    # festival_nominations table - Remove redundant index (#16)
    # ============================================

    # Redundant: covered by festival_nominations_unique_nomination_idx
    # which has the same columns (ceremony_id, category_id, movie_id) but is unique
    drop_if_exists index(:festival_nominations, [:ceremony_id, :category_id, :movie_id],
      name: :festival_nominations_ceremony_id_category_id_movie_id_index)

    # ============================================
    # movies table - Add year extraction index (#32)
    # ============================================

    # Supports queries like: WHERE EXTRACT(YEAR FROM release_date) = ?
    # Used in filters.ex, custom_filters.ex, year_imports_live.ex,
    # daily_year_import_worker.ex, movie_predictor.ex, collaborations.ex
    create index(:movies, ["EXTRACT(YEAR FROM release_date)"],
      name: :idx_movies_release_year)
  end

  def down do
    # Remove the year extraction index
    drop_if_exists index(:movies, ["EXTRACT(YEAR FROM release_date)"],
      name: :idx_movies_release_year)

    # Recreate the redundant festival_nominations index
    create_if_not_exists index(:festival_nominations, [:ceremony_id, :category_id, :movie_id],
      name: :festival_nominations_ceremony_id_category_id_movie_id_index)
  end
end
