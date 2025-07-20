defmodule Cinegraph.Repo.Migrations.CreateComprehensiveSchema do
  use Ecto.Migration

  def change do
    # 1. Movies - Core table with all fields
    create table(:movies, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      
      # Basic Info
      add :imdb_id, :string
      add :title, :string, null: false
      add :original_title, :string
      add :tagline, :string
      add :overview, :text
      add :homepage, :string
      
      # Dates & Status
      add :release_date, :date
      add :status, :string
      add :runtime, :integer
      
      # Financial
      add :budget, :bigint
      add :revenue, :bigint
      
      # Ratings & Popularity
      add :popularity, :float
      add :vote_average, :float
      add :vote_count, :integer
      
      # Classification
      add :adult, :boolean, default: false
      add :original_language, :string
      
      # Media
      add :poster_path, :string
      add :backdrop_path, :string
      add :images, :map, default: %{}  # Will store all image arrays
      
      # Relationships
      add :collection_id, :integer
      add :genre_ids, {:array, :integer}, default: []
      add :production_company_ids, {:array, :integer}, default: []
      add :production_countries, {:array, :string}, default: []
      add :spoken_languages, {:array, :string}, default: []
      
      # External IDs
      add :external_ids, :map, default: %{}
      
      # Metadata
      add :tmdb_raw_data, :map
      add :tmdb_fetched_at, :utc_datetime
      add :tmdb_last_updated, :utc_datetime
      
      # CRI fields
      add :cri_score, :float
      add :cri_components, :map
      add :cri_last_calculated, :utc_datetime
      
      timestamps()
    end
    
    create unique_index(:movies, [:tmdb_id])
    create index(:movies, [:imdb_id])
    create index(:movies, [:release_date])
    create index(:movies, [:popularity])
    create index(:movies, [:vote_average])
    create index(:movies, [:collection_id])
    create index(:movies, [:cri_score])

    # 2. People - Comprehensive person data
    create table(:people, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      
      # Basic Info
      add :imdb_id, :string
      add :name, :string, null: false
      add :also_known_as, {:array, :string}, default: []
      add :biography, :text
      add :birthday, :date
      add :deathday, :date
      add :place_of_birth, :string
      add :homepage, :string
      
      # Demographics
      add :gender, :integer
      add :adult, :boolean, default: false
      add :popularity, :float
      add :known_for_department, :string
      
      # Images
      add :profile_path, :string
      add :images, :map, default: %{}
      
      # External IDs
      add :external_ids, :map, default: %{}
      
      # Metadata
      add :tmdb_raw_data, :map
      add :tmdb_fetched_at, :utc_datetime
      add :tmdb_last_updated, :utc_datetime
      
      # CRI metrics
      add :influence_score, :float
      add :career_longevity_score, :float
      add :cross_cultural_impact, :float
      
      timestamps()
    end
    
    create unique_index(:people, [:tmdb_id])
    create index(:people, [:imdb_id])
    create index(:people, [:name])
    create index(:people, [:known_for_department])
    create index(:people, [:popularity])
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

    # === JUNCTION TABLES ===

    # 7. Movie Credits (Cast & Crew)
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

    # 8. Movie Keywords
    create table(:movie_keywords) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :keyword_id, references(:keywords, on_delete: :delete_all), null: false
      
      timestamps()
    end
    
    create unique_index(:movie_keywords, [:movie_id, :keyword_id])

    # 9. Movie Production Companies (junction)
    create table(:movie_production_companies) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :production_company_id, references(:production_companies, on_delete: :delete_all), null: false
      
      timestamps()
    end
    
    create unique_index(:movie_production_companies, [:movie_id, :production_company_id])

    # === ADDITIONAL DATA TABLES ===

    # 10. Movie Videos (Trailers, Clips, etc.)
    create table(:movie_videos) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :tmdb_id, :string, null: false
      add :name, :string
      add :key, :string  # YouTube/Vimeo ID
      add :site, :string  # YouTube/Vimeo
      add :type, :string  # Trailer/Teaser/Clip/Featurette/Behind the Scenes
      add :size, :integer  # 360/480/720/1080
      add :iso_639_1, :string  # Language code
      add :iso_3166_1, :string  # Country code
      add :official, :boolean
      add :published_at, :utc_datetime
      
      timestamps()
    end
    
    create index(:movie_videos, [:movie_id])
    create unique_index(:movie_videos, [:tmdb_id])
    create index(:movie_videos, [:type])
    create index(:movie_videos, [:site])

    # 11. Movie Release Dates (by country)
    create table(:movie_release_dates) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :country_code, :string, null: false  # ISO 3166-1
      add :release_date, :utc_datetime
      add :certification, :string  # PG, PG-13, R, etc.
      add :type, :integer  # 1=Premiere, 2=Theatrical (limited), 3=Theatrical, 4=Digital, 5=Physical, 6=TV
      add :note, :string
      
      timestamps()
    end
    
    create index(:movie_release_dates, [:movie_id])
    create index(:movie_release_dates, [:country_code])
    create unique_index(:movie_release_dates, [:movie_id, :country_code, :type])

    # 12. Movie Recommendations
    create table(:movie_recommendations) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :recommended_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :recommendation_order, :integer
      
      timestamps()
    end
    
    create unique_index(:movie_recommendations, [:movie_id, :recommended_movie_id])
    create index(:movie_recommendations, [:recommended_movie_id])

    # 13. Similar Movies
    create table(:similar_movies) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :similar_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :similarity_order, :integer
      
      timestamps()
    end
    
    create unique_index(:similar_movies, [:movie_id, :similar_movie_id])
    create index(:similar_movies, [:similar_movie_id])

    # 14. Movie Alternative Titles
    create table(:movie_alternative_titles) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :iso_3166_1, :string  # Country code
      add :title, :string
      add :type, :string
      
      timestamps()
    end
    
    create index(:movie_alternative_titles, [:movie_id])
    create index(:movie_alternative_titles, [:iso_3166_1])

    # 15. Movie Translations
    create table(:movie_translations) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :iso_3166_1, :string  # Country code
      add :iso_639_1, :string   # Language code
      add :name, :string        # Localized name
      add :english_name, :string
      add :data, :map          # Contains title, overview, homepage, tagline
      
      timestamps()
    end
    
    create index(:movie_translations, [:movie_id])
    create unique_index(:movie_translations, [:movie_id, :iso_3166_1, :iso_639_1])
  end
end