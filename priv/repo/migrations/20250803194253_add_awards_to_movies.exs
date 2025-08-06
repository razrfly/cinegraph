defmodule Cinegraph.Repo.Migrations.AddAwardsToMovies do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :awards, :jsonb, default: "{}"
    end

    # Create index for querying Oscar nominations
    create index(:movies, ["(awards -> 'oscar_nominations')"], using: :gin)
  end
end
