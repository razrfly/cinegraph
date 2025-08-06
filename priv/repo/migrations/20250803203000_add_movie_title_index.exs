defmodule Cinegraph.Repo.Migrations.AddMovieTitleIndex do
  use Ecto.Migration

  def change do
    # Add index on movies.title for faster title lookups
    create index(:movies, [:title])

    # Add composite index on title and release_date for common queries
    create index(:movies, [:title, :release_date])
  end
end
