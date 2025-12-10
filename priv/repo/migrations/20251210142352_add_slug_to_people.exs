defmodule Cinegraph.Repo.Migrations.AddSlugToPeople do
  use Ecto.Migration

  def change do
    alter table(:people) do
      add :slug, :string
    end

    # Create unique index for slugs (this also provides fast lookups)
    create unique_index(:people, [:slug])
  end
end
