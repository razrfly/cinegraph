defmodule Cinegraph.Repo.Migrations.AddMovieCreditsJobPersonIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # PlanetScale recommendation #33: Add index for job + person_id queries
    # This index improves performance for filtering movie credits by role (director, writer, etc.)
    # CONCURRENTLY avoids locking the table during index creation
    create index(:movie_credits, [:job, :person_id], concurrently: true)
  end
end
