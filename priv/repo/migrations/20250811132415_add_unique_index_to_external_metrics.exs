defmodule Cinegraph.Repo.Migrations.AddUniqueIndexToExternalMetrics do
  use Ecto.Migration

  def up do
    # First, remove duplicates by keeping only the most recent entry for each combination
    execute """
    DELETE FROM external_metrics em1
    WHERE EXISTS (
      SELECT 1 FROM external_metrics em2
      WHERE em2.movie_id = em1.movie_id
        AND em2.source = em1.source
        AND em2.metric_type = em1.metric_type
        AND (em2.fetched_at > em1.fetched_at 
             OR (em2.fetched_at = em1.fetched_at AND em2.id > em1.id))
    )
    """
    
    # Now add the unique index on (movie_id, source, metric_type) for upsert operations
    # This allows upserting the latest value for a metric without considering fetched_at
    create unique_index(:external_metrics, [:movie_id, :source, :metric_type],
      name: :external_metrics_movie_source_type_index
    )
  end
  
  def down do
    drop index(:external_metrics, [:movie_id, :source, :metric_type],
      name: :external_metrics_movie_source_type_index
    )
  end
end