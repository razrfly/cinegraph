defmodule Cinegraph.Repo.Migrations.AddImportStateCompositeIndex do
  use Ecto.Migration

  def change do
    # Add a composite index for efficient import_state lookups
    # This covers the query pattern: WHERE source = ? AND operation = 'import_state' AND success = true ORDER BY inserted_at DESC
    create index(
      :api_lookup_metrics,
      [:source, :operation, :success, :inserted_at],
      name: :api_lookup_metrics_import_state_idx,
      where: "operation = 'import_state'",
      comment: "Optimized index for import_state queries"
    )
    
    # Also add an index for the cleanup query that needs to find max IDs per key
    create index(
      :api_lookup_metrics,
      [:operation, :source, :target_identifier, :id],
      name: :api_lookup_metrics_import_state_cleanup_idx,
      where: "operation = 'import_state'",
      comment: "Optimized index for import_state cleanup queries"
    )
  end
end