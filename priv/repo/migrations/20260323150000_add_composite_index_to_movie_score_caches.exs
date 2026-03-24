defmodule Cinegraph.Repo.Migrations.AddCompositeIndexToMovieScoreCaches do
  use Ecto.Migration

  # concurrently: true requires non-transactional DDL
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Fully covers list_movies_by_disparity_category/2:
    # WHERE disparity_category = ? ORDER BY disparity_score DESC, id ASC
    execute """
    CREATE INDEX CONCURRENTLY idx_score_caches_category_score
    ON movie_score_caches (disparity_category ASC, disparity_score DESC, id ASC)
    """
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS idx_score_caches_category_score"
  end
end
