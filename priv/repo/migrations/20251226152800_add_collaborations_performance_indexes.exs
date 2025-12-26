defmodule Cinegraph.Repo.Migrations.AddCollaborationsPerformanceIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Support trending queries filtering by first_collaboration_date
    create index(:collaborations, [:first_collaboration_date, :collaboration_count],
      concurrently: true,
      name: :idx_collaborations_first_collab_date
    )

    # Support year filtering on collaboration_details joins
    create index(:collaboration_details, [:year, :collaboration_id],
      concurrently: true,
      name: :idx_collaboration_details_year_collab_id
    )

    # Partial index for high-count collaborations (common filter pattern)
    create index(:collaborations, [:collaboration_count],
      concurrently: true,
      where: "collaboration_count > 2",
      name: :idx_collaborations_high_count_partial
    )
  end
end
