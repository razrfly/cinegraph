defmodule Cinegraph.Repo.Migrations.DropUnusedTables do
  use Ecto.Migration

  def up do
    # Drop the unused person_relationships table (broken caching that was never working)
    drop table(:person_relationships)

    # Drop the unused skipped_imports table (never implemented, using import_status field instead)
    drop table(:skipped_imports)
  end

  def down do
    # Recreate person_relationships table if rolling back
    create table(:person_relationships) do
      add :from_person_id, references(:people, on_delete: :delete_all), null: false
      add :to_person_id, references(:people, on_delete: :delete_all), null: false
      add :degree, :integer, null: false
      add :path_count, :integer, default: 1
      add :shortest_path, {:array, :integer}, null: false
      add :strongest_connection_score, :decimal, precision: 5, scale: 2
      add :calculated_at, :timestamptz, default: fragment("NOW()")
      add :expires_at, :timestamptz, default: fragment("NOW() + interval '7 days'")
    end

    create unique_index(:person_relationships, [:from_person_id, :to_person_id])
    create index(:person_relationships, [:degree, :from_person_id])
    create index(:person_relationships, :expires_at)

    create constraint(:person_relationships, :valid_degree, check: "degree BETWEEN 1 AND 6")

    # Recreate skipped_imports table if rolling back
    create table(:skipped_imports) do
      add :tmdb_id, :integer, null: false
      add :title, :string
      add :reason, :string
      add :criteria_failed, :map
      add :checked_at, :utc_datetime_usec, default: fragment("NOW()")

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:skipped_imports, [:tmdb_id])
    create index(:skipped_imports, [:checked_at])
  end
end
