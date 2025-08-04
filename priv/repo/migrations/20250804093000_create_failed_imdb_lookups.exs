defmodule Cinegraph.Repo.Migrations.CreateFailedImdbLookups do
  use Ecto.Migration

  def change do
    create table(:failed_imdb_lookups) do
      add :imdb_id, :string, null: false
      add :title, :string
      add :year, :integer
      add :source, :string, null: false
      add :source_key, :string
      add :reason, :string, null: false
      add :metadata, :map, default: %{}
      add :retry_count, :integer, default: 0
      add :last_retry_at, :utc_datetime
      
      timestamps()
    end

    create index(:failed_imdb_lookups, [:imdb_id])
    create index(:failed_imdb_lookups, [:source])
    create index(:failed_imdb_lookups, [:reason])
    create unique_index(:failed_imdb_lookups, [:imdb_id, :source, :source_key])
  end
end