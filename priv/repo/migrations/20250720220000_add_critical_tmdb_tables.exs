defmodule Cinegraph.Repo.Migrations.AddCriticalTmdbTables do
  use Ecto.Migration

  def change do
    # ========================================
    # CRITICAL MISSING TABLES FOR CRI
    # ========================================
    
    # 1. Movie Watch Providers - Critical for streaming reach
    create table(:movie_watch_providers, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :country_code, :string, size: 2, null: false
      add :provider_id, :integer, null: false
      add :provider_name, :string
      add :provider_type, :string  # 'flatrate', 'rent', 'buy', 'ads', 'free'
      add :display_priority, :integer
      add :logo_path, :string
      add :link_url, :text
      
      # Metadata
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:movie_watch_providers, [:movie_id])
    create index(:movie_watch_providers, [:country_code])
    create index(:movie_watch_providers, [:provider_id])
    create index(:movie_watch_providers, [:provider_type])
    create unique_index(:movie_watch_providers, [:movie_id, :country_code, :provider_id, :provider_type])
    
    # 2. Movie Reviews - Critical for sentiment analysis
    create table(:movie_reviews, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :tmdb_review_id, :string, null: false
      add :author, :string
      add :author_details, :map, default: %{}  # rating, username, avatar_path
      add :content, :text
      add :url, :text
      
      # TMDb timestamps
      add :tmdb_created_at, :utc_datetime
      add :tmdb_updated_at, :utc_datetime
      
      # Our metadata
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:movie_reviews, [:movie_id])
    create unique_index(:movie_reviews, [:tmdb_review_id])
    create index(:movie_reviews, [:author])
    create index(:movie_reviews, [:tmdb_created_at])
    
    # 3. Movie Lists - User-created lists containing movies
    create table(:movie_lists, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :tmdb_list_id, :string, null: false
      add :list_name, :string
      add :description, :text
      add :list_type, :string  # 'user', 'official', 'editorial'
      add :item_count, :integer
      add :iso_639_1, :string
      
      # Metadata
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:movie_lists, [:movie_id])
    create index(:movie_lists, [:tmdb_list_id])
    create unique_index(:movie_lists, [:movie_id, :tmdb_list_id])
    
    # 4. Now Playing Movies - Current theatrical releases
    create table(:movie_now_playing, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :region, :string, size: 2
      add :page, :integer
      add :position, :integer
      
      # Dates from TMDb
      add :dates_minimum, :date
      add :dates_maximum, :date
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:movie_now_playing, [:movie_id])
    create index(:movie_now_playing, [:region])
    create index(:movie_now_playing, [:fetched_at])
    create unique_index(:movie_now_playing, [:movie_id, :region, :fetched_at])
    
    # 5. Upcoming Movies - Future theatrical releases
    create table(:movie_upcoming, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :region, :string, size: 2
      add :page, :integer
      add :position, :integer
      
      # Dates from TMDb
      add :dates_minimum, :date
      add :dates_maximum, :date
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:movie_upcoming, [:movie_id])
    create index(:movie_upcoming, [:region])
    create index(:movie_upcoming, [:fetched_at])
    create unique_index(:movie_upcoming, [:movie_id, :region, :fetched_at])
    
    # 6. Certifications - Content ratings by country
    create table(:certifications, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :country_code, :string, size: 2, null: false
      add :certification, :string, null: false
      add :meaning, :text
      add :order_index, :integer
      
      timestamps()
    end
    
    create unique_index(:certifications, [:country_code, :certification])
    create index(:certifications, [:country_code])
    
    # 7. Watch Provider Registry - Master list of providers
    create table(:watch_providers, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :provider_id, :integer, null: false
      add :provider_name, :string
      add :logo_path, :string
      add :display_priority, :integer
      
      timestamps()
    end
    
    create unique_index(:watch_providers, [:provider_id])
    create index(:watch_providers, [:provider_name])
    
    # 8. Watch Provider Regions - Available regions per provider
    create table(:watch_provider_regions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :provider_id, :integer, null: false
      add :country_code, :string, size: 2, null: false
      add :native_name, :string
      add :english_name, :string
      
      timestamps()
    end
    
    create index(:watch_provider_regions, [:provider_id])
    create index(:watch_provider_regions, [:country_code])
    create unique_index(:watch_provider_regions, [:provider_id, :country_code])
    
    # 9. TMDb Configuration - System configuration
    create table(:tmdb_configuration, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :images, :map  # base_url, secure_base_url, backdrop_sizes, etc.
      add :change_keys, {:array, :string}, default: []
      add :fetched_at, :utc_datetime
      
      timestamps()
    end
    
    create index(:tmdb_configuration, [:fetched_at])
    
    # 10. Countries - TMDb country list
    create table(:countries, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :iso_3166_1, :string, size: 2, null: false
      add :english_name, :string
      add :native_name, :string
      
      timestamps()
    end
    
    create unique_index(:countries, [:iso_3166_1])
    
    # 11. Languages - TMDb language list
    create table(:languages, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :iso_639_1, :string, size: 2, null: false
      add :english_name, :string
      add :native_name, :string
      
      timestamps()
    end
    
    create unique_index(:languages, [:iso_639_1])
    
    # ========================================
    # ENHANCED TRENDING FOR PEOPLE
    # ========================================
    
    # Add person trending support to external_trending
    # Note: This modifies the existing external_trending table concept
    # to support both movies and people
    
    create table(:person_trending, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      
      add :time_window, :string  # 'day', 'week'
      add :rank, :integer
      add :score, :float
      add :known_for_titles, {:array, :string}, default: []  # Movie/TV titles they're known for
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:person_trending, [:source_id, :time_window, :fetched_at])
    create index(:person_trending, [:person_id])
    create unique_index(:person_trending, [:person_id, :source_id, :time_window, :fetched_at])
  end
end