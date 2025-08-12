defmodule Cinegraph.Repo.Migrations.AddUniqueIndexToExternalMetrics do
  use Ecto.Migration

  def up do
    # First, remove duplicates by keeping only the most recent entry per (movie_id, source, metric_type)
    # Uses a window function for better performance on larger tables.
    execute """
    DELETE FROM external_metrics em
    USING (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY movie_id, source, metric_type
               ORDER BY fetched_at DESC, id DESC
             ) AS rn
      FROM external_metrics
    ) dups
    WHERE em.id = dups.id AND dups.rn > 1;
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
