defmodule Cinegraph.Repo.Migrations.AddCanonicalSourcesToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :canonical_sources, :map, default: %{}
    end

    # GIN index for fast JSONB operations
    create index(:movies, [:canonical_sources], using: :gin)

    # Functional index for 1001 Movies queries (most common backtesting use case)
    create index(:movies, ["(canonical_sources ? '1001_movies')"],
             name: :idx_movies_1001_movies,
             where: "canonical_sources ? '1001_movies'"
           )

    # Functional index for any canonical source
    create index(:movies, ["(canonical_sources != '{}')"],
             name: :idx_movies_any_canonical,
             where: "canonical_sources != '{}'"
           )
  end
end
