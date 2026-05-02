defmodule Cinegraph.Repo.Migrations.CreateWatchAvailabilityTables do
  use Ecto.Migration

  def change do
    create table(:watch_providers) do
      add :source, :string, null: false, default: "tmdb", size: 50
      add :source_provider_id, :string, null: false, size: 100
      add :tmdb_provider_id, :integer
      add :name, :string, null: false
      add :logo_path, :string
      add :display_priorities, :map, default: %{}
      add :active, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:watch_providers, [:source, :source_provider_id])
    create index(:watch_providers, [:tmdb_provider_id])
    create index(:watch_providers, [:name])
    create index(:watch_providers, [:active])

    create table(:watch_provider_regions) do
      add :iso_3166_1, :string, null: false, size: 2
      add :english_name, :string, null: false
      add :native_name, :string
      add :source, :string, null: false, default: "tmdb", size: 50
      add :active, :boolean, null: false, default: true
      add :last_seen_at, :utc_datetime
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:watch_provider_regions, [:source, :iso_3166_1])
    create index(:watch_provider_regions, [:active])

    create table(:movie_availability_refreshes) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :region, :string, null: false, size: 2
      add :source, :string, null: false, default: "tmdb", size: 50
      add :status, :string, null: false, size: 50
      add :error_reason, :text
      add :tmdb_link, :text
      add :fetched_at, :utc_datetime, null: false
      add :stale_after, :utc_datetime, null: false
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(:movie_availability_refreshes, [:movie_id, :region, :source],
             name: :movie_availability_refresh_unique_idx
           )

    create index(:movie_availability_refreshes, [:region, :status])
    create index(:movie_availability_refreshes, [:fetched_at])
    create index(:movie_availability_refreshes, [:stale_after])

    create table(:movie_watch_providers) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :watch_provider_id, references(:watch_providers, on_delete: :delete_all), null: false
      add :region, :string, null: false, size: 2
      add :monetization_type, :string, null: false, size: 50
      add :display_priority, :integer
      add :tmdb_link, :text
      add :source, :string, null: false, default: "tmdb", size: 50
      add :fetched_at, :utc_datetime, null: false
      add :stale_after, :utc_datetime, null: false
      add :metadata, :map, default: %{}

      timestamps()
    end

    create unique_index(
             :movie_watch_providers,
             [:movie_id, :watch_provider_id, :region, :monetization_type, :source],
             name: :movie_watch_provider_unique_idx
           )

    create index(:movie_watch_providers, [:movie_id, :region])
    create index(:movie_watch_providers, [:region, :monetization_type])
    create index(:movie_watch_providers, [:watch_provider_id, :region, :monetization_type])
    create index(:movie_watch_providers, [:fetched_at])
    create index(:movie_watch_providers, [:stale_after])
  end
end
