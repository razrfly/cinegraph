defmodule Cinegraph.Repo.Migrations.AddSlugToMoviesTable do
  use Ecto.Migration

  def change do
    alter table(:movies) do
      add :slug, :string
    end

    create unique_index(:movies, [:slug])
  end
end