defmodule Cinegraph.Repo.Migrations.DropOscarTables do
  use Ecto.Migration

  def up do
    # Drop Oscar tables as they have been migrated to festival_* tables
    # All data has been successfully migrated and verified

    # Drop views first
    execute "DROP VIEW IF EXISTS movie_oscar_stats"
    execute "DROP VIEW IF EXISTS person_oscar_stats"

    # Drop tables in dependency order (if they exist)
    execute "DROP TABLE IF EXISTS oscar_nominations"
    execute "DROP TABLE IF EXISTS oscar_categories"
    execute "DROP TABLE IF EXISTS oscar_ceremonies"
  end

  def down do
    # Recreate tables if rollback is needed
    # Note: This won't restore data - data should be re-imported from festival tables

    create table(:oscar_ceremonies) do
      add :ceremony_number, :integer, null: false
      add :year, :integer, null: false
      add :ceremony_date, :date
      add :data, :jsonb, null: false

      timestamps()
    end

    create unique_index(:oscar_ceremonies, [:year])
    create unique_index(:oscar_ceremonies, [:ceremony_number])

    create table(:oscar_categories) do
      add :name, :text, null: false
      # 'person', 'film', 'technical'
      add :category_type, :text, null: false
      add :is_major, :boolean, default: false
      # true only for actor/director awards
      add :tracks_person, :boolean, default: false

      timestamps()
    end

    create unique_index(:oscar_categories, [:name])

    create table(:oscar_nominations) do
      add :ceremony_id, references(:oscar_ceremonies, on_delete: :delete_all), null: false
      add :category_id, references(:oscar_categories, on_delete: :restrict), null: false
      add :movie_id, references(:movies, on_delete: :delete_all)
      add :person_id, references(:people, on_delete: :delete_all)
      add :won, :boolean, null: false, default: false
      add :details, :jsonb, default: "{}"

      timestamps()
    end

    # Indexes for fast queries
    create index(:oscar_nominations, [:movie_id])
    create index(:oscar_nominations, [:person_id])
    create index(:oscar_nominations, [:won], where: "won = true")
    create index(:oscar_nominations, [:ceremony_id, :category_id])

    # Unique constraint to prevent duplicate nominations
    create unique_index(:oscar_nominations, [:ceremony_id, :category_id, :movie_id])

    # Ensure we have either a movie or person (or both)
    create constraint(:oscar_nominations, :must_have_movie_or_person,
             check: "movie_id IS NOT NULL OR person_id IS NOT NULL"
           )
  end
end
