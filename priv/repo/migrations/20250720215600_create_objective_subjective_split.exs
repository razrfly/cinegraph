defmodule Cinegraph.Repo.Migrations.CreateObjectiveSubjectiveSplit do
  use Ecto.Migration

  def change do
    # ========================================
    # CORE OBJECTIVE DATA
    # ========================================
    
    # 1. Movies - Only objective facts
    create table(:movies, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :imdb_id, :string
      
      # Core objective attributes
      add :title, :string, null: false
      add :original_title, :string
      add :release_date, :date
      add :runtime, :integer  # in minutes
      add :overview, :text
      add :tagline, :string
      add :original_language, :string
      add :budget, :bigint
      add :revenue, :bigint
      add :status, :string
      add :adult, :boolean, default: false
      add :homepage, :string
      
      # Foreign keys
      add :collection_id, :bigint
      
      # Media paths (objective - just paths)
      add :poster_path, :string
      add :backdrop_path, :string
      
      # JSONB for flexible storage
      add :images, :map, default: %{}  # All image arrays
      add :genre_ids, {:array, :integer}, default: []
      add :spoken_languages, {:array, :string}, default: []
      add :production_countries, {:array, :string}, default: []
      add :production_company_ids, {:array, :integer}, default: []
      add :external_ids, :map, default: %{}  # imdb, facebook, etc.
      
      # TMDB metadata
      add :tmdb_raw_data, :map
      add :tmdb_fetched_at, :utc_datetime
      add :tmdb_last_updated, :utc_datetime
      
      timestamps()
    end
    
    create unique_index(:movies, [:tmdb_id])
    create index(:movies, [:imdb_id])
    create index(:movies, [:release_date])
    create index(:movies, [:collection_id])
    
    # 2. People - Only objective facts
    create table(:people, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :imdb_id, :string
      
      # Core attributes
      add :name, :string, null: false
      add :also_known_as, {:array, :string}, default: []
      add :gender, :integer
      add :birthday, :date
      add :deathday, :date
      add :place_of_birth, :string
      add :biography, :text
      add :known_for_department, :string
      add :adult, :boolean, default: false
      add :homepage, :string
      
      # Media
      add :profile_path, :string
      add :images, :map, default: %{}
      
      # External references
      add :external_ids, :map, default: %{}
      
      # TMDB metadata
      add :tmdb_raw_data, :map
      add :tmdb_fetched_at, :utc_datetime
      add :tmdb_last_updated, :utc_datetime
      
      timestamps()
    end
    
    create unique_index(:people, [:tmdb_id])
    create index(:people, [:imdb_id])
    create index(:people, [:name])
    create index(:people, [:known_for_department])
    create index(:people, [:birthday])
    
    # 3. Genres
    create table(:genres, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      
      timestamps()
    end
    
    create unique_index(:genres, [:tmdb_id])
    create unique_index(:genres, [:name])
    
    # 4. Collections (Movie franchises)
    create table(:collections, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :name, :string
      add :overview, :text
      add :poster_path, :string
      add :backdrop_path, :string
      add :images, :map, default: %{}
      
      timestamps()
    end
    
    create unique_index(:collections, [:tmdb_id])
    create index(:collections, [:name])
    
    # 5. Production Companies
    create table(:production_companies, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :name, :string
      add :description, :text
      add :headquarters, :string
      add :homepage, :string
      add :logo_path, :string
      add :origin_country, :string
      add :parent_company_id, :integer
      
      timestamps()
    end
    
    create unique_index(:production_companies, [:tmdb_id])
    create index(:production_companies, [:name])
    create index(:production_companies, [:origin_country])
    
    # 6. Keywords
    create table(:keywords, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      
      timestamps()
    end
    
    create unique_index(:keywords, [:tmdb_id])
    create index(:keywords, [:name])
    
    # ========================================
    # JUNCTION TABLES
    # ========================================
    
    # Movie Credits (Cast & Crew)
    create table(:movie_credits) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :credit_type, :string, null: false  # "cast" or "crew"
      
      # Cast fields
      add :character, :string
      add :cast_order, :integer
      
      # Crew fields
      add :department, :string
      add :job, :string
      
      # Metadata
      add :credit_id, :string
      
      timestamps()
    end
    
    create index(:movie_credits, [:movie_id])
    create index(:movie_credits, [:person_id])
    create index(:movie_credits, [:credit_type])
    create index(:movie_credits, [:department, :job])
    create unique_index(:movie_credits, [:credit_id])
    
    # Movie Keywords
    create table(:movie_keywords, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :keyword_id, references(:keywords, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_keywords, [:movie_id, :keyword_id])
    
    # Movie Production Companies
    create table(:movie_production_companies, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :production_company_id, references(:production_companies, on_delete: :delete_all), null: false
      timestamps()
    end
    
    create unique_index(:movie_production_companies, [:movie_id, :production_company_id])
    
    # Movie Videos
    create table(:movie_videos, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :tmdb_id, :string, null: false
      add :iso_639_1, :string
      add :iso_3166_1, :string
      add :key, :string  # YouTube/Vimeo key
      add :name, :string
      add :site, :string
      add :size, :integer
      add :type, :string  # Trailer, Teaser, Clip, etc.
      add :official, :boolean
      add :published_at, :utc_datetime
      
      timestamps()
    end
    
    create index(:movie_videos, [:movie_id])
    create unique_index(:movie_videos, [:tmdb_id])
    create index(:movie_videos, [:type])
    create index(:movie_videos, [:site])
    
    # Movie Release Dates
    create table(:movie_release_dates, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :country_code, :string, null: false  # ISO 3166-1
      add :release_date, :utc_datetime
      add :type, :integer  # 1-6 (premiere, theatrical, digital, etc.)
      add :certification, :string  # PG, R, etc.
      add :note, :string
      
      timestamps()
    end
    
    create index(:movie_release_dates, [:movie_id])
    create index(:movie_release_dates, [:country_code])
    create unique_index(:movie_release_dates, [:movie_id, :country_code, :type])
    
    # Alternative Titles
    create table(:movie_alternative_titles, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :iso_3166_1, :string
      add :title, :string
      add :type, :string
      
      timestamps()
    end
    
    create index(:movie_alternative_titles, [:movie_id])
    create index(:movie_alternative_titles, [:iso_3166_1])
    
    # Translations
    create table(:movie_translations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :iso_3166_1, :string, null: false
      add :iso_639_1, :string, null: false
      add :name, :string
      add :english_name, :string
      add :data, :map  # Contains title, overview, homepage, tagline
      
      timestamps()
    end
    
    create index(:movie_translations, [:movie_id])
    create unique_index(:movie_translations, [:movie_id, :iso_3166_1, :iso_639_1])
    
    # ========================================
    # EXTERNAL SOURCES & SUBJECTIVE DATA
    # ========================================
    
    # External Data Sources Registry
    create table(:external_sources, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false  # 'tmdb', 'rotten_tomatoes', 'imdb'
      add :source_type, :string  # 'api', 'scraper', 'manual'
      add :base_url, :string
      add :api_version, :string
      add :weight_factor, :float, default: 1.0
      add :active, :boolean, default: true
      
      # Configuration as embedded JSON
      add :config, :map, default: %{}
      
      timestamps()
    end
    
    create unique_index(:external_sources, [:name])
    
    # External Ratings (Polymorphic for any source)
    create table(:external_ratings, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      
      add :rating_type, :string, null: false  # 'user', 'critic', 'algorithm', 'popularity'
      add :value, :float, null: false
      add :scale_min, :float, default: 0.0
      add :scale_max, :float, default: 10.0
      add :sample_size, :integer
      
      # Source-specific metadata
      add :metadata, :map, default: %{}
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:external_ratings, [:movie_id])
    create index(:external_ratings, [:source_id])
    create unique_index(:external_ratings, [:movie_id, :source_id, :rating_type])
    
    # External Recommendations (Movie to Movie relationships)
    create table(:external_recommendations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :source_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :recommended_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      
      add :recommendation_type, :string  # 'similar', 'recommended'
      add :score, :float
      add :rank, :integer
      
      # Algorithm metadata
      add :algorithm_data, :map, default: %{}
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:external_recommendations, [:source_movie_id])
    create index(:external_recommendations, [:recommended_movie_id])
    create index(:external_recommendations, [:source_id])
    create unique_index(:external_recommendations, [:source_movie_id, :recommended_movie_id, :source_id, :recommendation_type])
    
    # Trending/Popular Movies by Source
    create table(:external_trending, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      
      add :time_window, :string  # 'day', 'week'
      add :rank, :integer
      add :score, :float
      add :region, :string  # ISO country code
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:external_trending, [:source_id, :time_window, :fetched_at])
    create index(:external_trending, [:movie_id])
    
    # ========================================
    # CRI SCORING TABLES (Future)
    # ========================================
    
    # CRI Scores (Our calculated scores)
    create table(:cri_scores, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      
      add :score, :float
      add :components, :map  # Breakdown of score components
      add :version, :string  # Algorithm version
      add :calculated_at, :utc_datetime
      
      timestamps()
    end
    
    create index(:cri_scores, [:movie_id])
    create index(:cri_scores, [:calculated_at])
  end
end