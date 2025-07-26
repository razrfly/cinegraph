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
      timestamps()
    end
    
    create unique_index(:movies, [:tmdb_id])
    create index(:movies, [:imdb_id])
    create index(:movies, [:release_date])
    create index(:movies, [:collection_id])

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

    # Keywords
    create table(:keywords) do
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      timestamps()
    end
    
    create unique_index(:keywords, [:tmdb_id])
    create index(:keywords, [:name])

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

    # Cultural authorities (critics, institutions)
    create table(:cultural_authorities) do
      add :name, :string, null: false
      add :authority_type, :string, null: false
      add :description, :text
      add :website, :string
      add :trust_score, :float, default: 5.0
      add :active, :boolean, default: true
      add :metadata, :map
      timestamps()
    end
    
    create index(:cultural_authorities, [:name])
    create index(:cultural_authorities, [:authority_type])
    create index(:cultural_authorities, [:trust_score])

    # Curated lists from cultural authorities
    create table(:curated_lists) do
      add :authority_id, references(:cultural_authorities, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :list_type, :string, null: false
      add :year, :integer
      add :total_items, :integer
      add :source_url, :string
      add :metadata, :map
      timestamps()
    end
    
    create unique_index(:curated_lists, [:authority_id, :name, :year])
    create index(:curated_lists, [:list_type])
    create index(:curated_lists, [:year])

    # Movie appearances in curated lists
    create table(:movie_list_items) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :list_id, references(:curated_lists, on_delete: :delete_all), null: false
      add :position, :integer
      add :award_category, :string
      add :award_result, :string
      add :year_awarded, :integer
      add :metadata, :map
      timestamps()
    end
    
    create unique_index(:movie_list_items, [:movie_id, :list_id, :award_category])
    create index(:movie_list_items, [:list_id])
    create index(:movie_list_items, [:movie_id])

    # CRI scores (calculated periodically)
    create table(:cri_scores) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :overall_score, :float, null: false
      add :timelessness_score, :float, null: false
      add :cultural_penetration_score, :float, null: false
      add :artistic_impact_score, :float, null: false
      add :institutional_recognition_score, :float, null: false
      add :public_reception_score, :float, null: false
      add :calculation_version, :string, null: false
      add :calculated_at, :utc_datetime, null: false
      add :metadata, :map
      timestamps()
    end
    
    create index(:cri_scores, [:movie_id])
    create index(:cri_scores, [:calculated_at])
  end
end
