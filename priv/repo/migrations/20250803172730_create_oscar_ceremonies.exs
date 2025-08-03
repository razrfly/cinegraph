defmodule Cinegraph.Repo.Migrations.CreateOscarCeremonies do
  use Ecto.Migration

  def change do
    create table(:oscar_ceremonies) do
      add :ceremony_number, :integer, null: false
      add :year, :integer, null: false
      add :ceremony_date, :date
      add :data, :jsonb, null: false
      
      timestamps()
    end

    create unique_index(:oscar_ceremonies, [:year])
    create unique_index(:oscar_ceremonies, [:ceremony_number])
  end
end