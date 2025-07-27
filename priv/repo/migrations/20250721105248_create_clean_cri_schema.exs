defmodule Cinegraph.Repo.Migrations.CreateCleanCriSchema do
  use Ecto.Migration

  def change do
    # Core movie data
    create table(:movies) do
      add :tmdb_id, :integer, null: false
      add :imdb_id, :string
      add :title, :string, null: false
      add :original_title, :string
      add :overview, :text
      add :release_date, :date
      add :runtime, :integer
      add :budget, :bigint
      add :revenue, :bigint
      add :vote_average, :float
      add :vote_count, :integer
      add :popularity, :float
      add :status, :string
      add :tagline, :string
      add :homepage, :string
      add :original_language, :string
      add :adult, :boolean, default: false
      add :backdrop_path, :string
      add :poster_path, :string
      add :collection_id, :integer
      add :tmdb_data, :map
      add :omdb_data, :map
      add :awards_text, :text
      add :box_office_domestic, :bigint
      add :origin_country, {:array, :string}, default: []
      timestamps()
    end
    
    create unique_index(:movies, [:tmdb_id])
    create index(:movies, [:imdb_id])
    create index(:movies, [:release_date])
    create index(:movies, [:collection_id])
    create index(:movies, [:origin_country], using: :gin)

    # People (directors, actors, etc.)
    create table(:people) do
      add :tmdb_id, :integer, null: false
      add :imdb_id, :string
      add :name, :string, null: false
      add :biography, :text
      add :birthday, :date
      add :deathday, :date
      add :place_of_birth, :string
      add :profile_path, :string
      add :known_for_department, :string
      add :gender, :integer
      add :popularity, :float
      add :adult, :boolean, default: false
      timestamps()
    end
    
    create unique_index(:people, [:tmdb_id])
    create index(:people, [:imdb_id])
    create index(:people, [:name])
    create index(:people, [:known_for_department])
    create index(:people, [:birthday])

    # Genres
    create table(:genres) do
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      timestamps()
    end
    
    create unique_index(:genres, [:tmdb_id])
    create index(:genres, [:name])

    # Collections
    create table(:collections) do
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      add :overview, :text
      add :poster_path, :string
      add :backdrop_path, :string
      timestamps()
    end
    
    create unique_index(:collections, [:tmdb_id])
    create index(:collections, [:name])

    # Production companies
    create table(:production_companies) do
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      add :logo_path, :string
      add :origin_country, :string
      timestamps()
    end
    
    create unique_index(:production_companies, [:tmdb_id])
    create index(:production_companies, [:name])
    create index(:production_companies, [:origin_country])

    # Production countries
    create table(:production_countries) do
      add :iso_3166_1, :string, null: false
      add :name, :string, null: false
      timestamps()
    end
    
    create unique_index(:production_countries, [:iso_3166_1])
    
    # Spoken languages
    create table(:spoken_languages) do
      add :iso_639_1, :string, null: false
      add :name, :string, null: false
      add :english_name, :string
      timestamps()
    end
    
    create unique_index(:spoken_languages, [:iso_639_1])

    # Keywords
    create table(:keywords) do
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      timestamps()
    end
    
    create unique_index(:keywords, [:tmdb_id])
    create index(:keywords, [:name])

    # Movie-Genre junction table
    create table(:movie_genres, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :genre_id, references(:genres, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_genres, [:movie_id, :genre_id])
    create index(:movie_genres, [:movie_id])
    create index(:movie_genres, [:genre_id])

    # Movie credits (cast and crew)
    create table(:movie_credits) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :credit_id, :string, null: false
      add :credit_type, :string, null: false  # "cast" or "crew"
      add :department, :string
      add :job, :string
      add :character, :string
      add :cast_order, :integer
      add :profile_path, :string
      timestamps()
    end
    
    create index(:movie_credits, [:movie_id])
    create index(:movie_credits, [:person_id])
    create index(:movie_credits, [:credit_type])
    create index(:movie_credits, [:department, :job])
    create unique_index(:movie_credits, [:credit_id])

    # Movie-Keyword junction table
    create table(:movie_keywords, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :keyword_id, references(:keywords, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_keywords, [:movie_id, :keyword_id])

    # Movie-Production Company junction table  
    create table(:movie_production_companies, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :production_company_id, references(:production_companies, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_production_companies, [:movie_id, :production_company_id])

    # Movie-Production Country junction table
    create table(:movie_production_countries, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :production_country_id, references(:production_countries, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_production_countries, [:movie_id, :production_country_id])
    create index(:movie_production_countries, [:movie_id])
    create index(:movie_production_countries, [:production_country_id])
    
    # Movie-Spoken Language junction table
    create table(:movie_spoken_languages, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :spoken_language_id, references(:spoken_languages, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_spoken_languages, [:movie_id, :spoken_language_id])
    create index(:movie_spoken_languages, [:movie_id])
    create index(:movie_spoken_languages, [:spoken_language_id])

    # Movie videos (trailers, etc.)
    create table(:movie_videos) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :tmdb_id, :string, null: false
      add :name, :string, null: false
      add :key, :string, null: false
      add :site, :string, null: false
      add :size, :integer
      add :type, :string, null: false
      add :official, :boolean, default: false
      add :published_at, :naive_datetime
      timestamps()
    end
    
    create index(:movie_videos, [:movie_id])
    create unique_index(:movie_videos, [:tmdb_id])
    create index(:movie_videos, [:type])
    create index(:movie_videos, [:site])

    # Movie release dates
    create table(:movie_release_dates) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :country_code, :string, null: false, size: 2
      add :certification, :string
      add :release_date, :naive_datetime
      add :release_type, :integer
      add :note, :string
      timestamps()
    end
    
    create index(:movie_release_dates, [:movie_id])
    create index(:movie_release_dates, [:country_code])
    create unique_index(:movie_release_dates, [:movie_id, :country_code, :release_type])

    # External sources (TMDb, OMDb, etc.)
    create table(:external_sources) do
      add :name, :string, null: false
      add :source_type, :string, null: false
      add :base_url, :string
      add :api_version, :string
      add :weight_factor, :float, default: 1.0
      add :active, :boolean, default: true
      add :config, :map
      timestamps()
    end
    
    create unique_index(:external_sources, [:name])

    # External ratings from various sources
    create table(:external_ratings) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      add :rating_type, :string, null: false
      add :value, :float, null: false
      add :scale_min, :float, default: 0.0
      add :scale_max, :float, default: 10.0
      add :metadata, :map
      add :fetched_at, :utc_datetime, null: false
      timestamps()
    end
    
    create index(:external_ratings, [:movie_id])
    create index(:external_ratings, [:source_id])
    create unique_index(:external_ratings, [:movie_id, :source_id, :rating_type])

    # External recommendations (similar/related movies)
    create table(:external_recommendations) do
      add :source_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :recommended_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      add :recommendation_type, :string, null: false
      add :score, :float
      add :metadata, :map
      add :fetched_at, :utc_datetime, null: false
      timestamps()
    end
    
    create index(:external_recommendations, [:source_movie_id])
    create index(:external_recommendations, [:recommended_movie_id])
    create index(:external_recommendations, [:source_id])
    create unique_index(:external_recommendations, [:source_movie_id, :recommended_movie_id, :source_id, :recommendation_type], name: :external_recs_unique_idx)

    # Note: Removed cultural_authorities, curated_lists, movie_list_items, and cri_scores tables
    # These will be added back when we implement the CRI scoring system
  end
end
