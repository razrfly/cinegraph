defmodule Cinegraph.Repo.Migrations.RemoveOldExternalMetricsIndex do
  use Ecto.Migration

  def up do
    # Drop the old 4-column unique index if it exists
    # This was created in 20250811084415_reorganize_database_for_metrics.exs
    # and conflicts with the new 3-column unique index
    execute """
    DROP INDEX IF EXISTS external_metrics_movie_id_source_metric_type_fetched_at_index;
    """
  end

  def down do
    # Recreate the old index in case of rollback
    # Note: this may fail if there are duplicate rows, which is expected
    create_if_not_exists unique_index(:external_metrics, [
                           :movie_id,
                           :source,
                           :metric_type,
                           :fetched_at
                         ])
  end
end
