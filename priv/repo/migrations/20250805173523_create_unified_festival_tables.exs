defmodule Cinegraph.Repo.Migrations.CreateUnifiedFestivalTables do
  use Ecto.Migration

  def change do
    # Festival organizations table
    create table(:festival_organizations) do
      add :name, :string, null: false
      add :abbreviation, :string
      add :country, :string
      add :founded_year, :integer
      add :website, :string
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:festival_organizations, [:name])
    create index(:festival_organizations, [:abbreviation])

    # Unified ceremonies table
    create table(:festival_ceremonies) do
      add :organization_id, references(:festival_organizations, on_delete: :delete_all),
        null: false

      add :year, :integer, null: false
      add :ceremony_number, :integer
      add :name, :string
      add :date, :date
      add :location, :string
      add :data, :map, default: %{}

      timestamps()
    end

    create unique_index(:festival_ceremonies, [:organization_id, :year])
    create index(:festival_ceremonies, [:year])
    create index(:festival_ceremonies, [:organization_id])

    # Unified categories table
    create table(:festival_categories) do
      add :organization_id, references(:festival_organizations, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :tracks_person, :boolean, default: false
      # 'film', 'person', 'technical', 'special'
      add :category_type, :string
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:festival_categories, [:organization_id, :name])
    create index(:festival_categories, [:tracks_person])
    create index(:festival_categories, [:category_type])

    # Unified nominations table
    create table(:festival_nominations) do
      add :ceremony_id, references(:festival_ceremonies, on_delete: :delete_all), null: false
      add :category_id, references(:festival_categories, on_delete: :restrict), null: false
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :nilify_all)
      add :won, :boolean, default: false
      # e.g., "Palme d'Or", "Golden Lion", "Golden Bear"
      add :prize_name, :string
      add :details, :map, default: %{}

      timestamps()
    end

    create index(:festival_nominations, [:ceremony_id])
    create index(:festival_nominations, [:category_id])
    create index(:festival_nominations, [:movie_id])
    create index(:festival_nominations, [:person_id])
    create index(:festival_nominations, [:won])
    create index(:festival_nominations, [:ceremony_id, :category_id])

    # Add constraint to ensure at least movie_id or person_id is present
    create constraint(:festival_nominations, :must_have_nominee, check: "movie_id IS NOT NULL")
  end
end
