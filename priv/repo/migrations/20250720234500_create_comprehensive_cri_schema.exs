defmodule Cinegraph.Repo.Migrations.CreateComprehensiveCriSchema do
  use Ecto.Migration

  def change do
    # ========================================
    # CORE OBJECTIVE DATA (from previous migration)
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
      add :runtime, :integer
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
      
      # Media paths
      add :poster_path, :string
      add :backdrop_path, :string
      
      # JSONB for flexible storage
      add :images, :map, default: %{}
      add :genre_ids, {:array, :integer}, default: []
      add :spoken_languages, {:array, :string}, default: []
      add :production_countries, {:array, :string}, default: []
      add :production_company_ids, {:array, :integer}, default: []
      add :external_ids, :map, default: %{}
      
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
    
    # 2. People
    create table(:people, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :imdb_id, :string
      
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
      
      add :profile_path, :string
      add :images, :map, default: %{}
      add :external_ids, :map, default: %{}
      
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
    
    # 3. Basic entity tables
    create table(:genres, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :tmdb_id, :integer, null: false
      add :name, :string, null: false
      timestamps()
    end
    
    create unique_index(:genres, [:tmdb_id])
    create unique_index(:genres, [:name])
    
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
    
    create table(:movie_credits) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :credit_type, :string, null: false
      add :character, :string
      add :cast_order, :integer
      add :department, :string
      add :job, :string
      add :credit_id, :string
      timestamps()
    end
    
    create index(:movie_credits, [:movie_id])
    create index(:movie_credits, [:person_id])
    create index(:movie_credits, [:credit_type])
    create index(:movie_credits, [:department, :job])
    create unique_index(:movie_credits, [:credit_id])
    
    create table(:movie_keywords, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :keyword_id, references(:keywords, on_delete: :delete_all), null: false
    end
    
    create unique_index(:movie_keywords, [:movie_id, :keyword_id])
    
    create table(:movie_production_companies, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :production_company_id, references(:production_companies, on_delete: :delete_all), null: false
      timestamps()
    end
    
    create unique_index(:movie_production_companies, [:movie_id, :production_company_id])
    
    create table(:movie_videos, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :tmdb_id, :string, null: false
      add :iso_639_1, :string
      add :iso_3166_1, :string
      add :key, :string
      add :name, :string
      add :site, :string
      add :size, :integer
      add :type, :string
      add :official, :boolean
      add :published_at, :utc_datetime
      timestamps()
    end
    
    create index(:movie_videos, [:movie_id])
    create unique_index(:movie_videos, [:tmdb_id])
    create index(:movie_videos, [:type])
    create index(:movie_videos, [:site])
    
    create table(:movie_release_dates, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :country_code, :string, null: false
      add :release_date, :utc_datetime
      add :type, :integer
      add :certification, :string
      add :note, :string
      timestamps()
    end
    
    create index(:movie_release_dates, [:movie_id])
    create index(:movie_release_dates, [:country_code])
    create unique_index(:movie_release_dates, [:movie_id, :country_code, :type])
    
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
    
    create table(:movie_translations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :iso_3166_1, :string, null: false
      add :iso_639_1, :string, null: false
      add :name, :string
      add :english_name, :string
      add :data, :map
      timestamps()
    end
    
    create index(:movie_translations, [:movie_id])
    create unique_index(:movie_translations, [:movie_id, :iso_3166_1, :iso_639_1])
    
    # ========================================
    # EXTERNAL SOURCES & SUBJECTIVE DATA
    # ========================================
    
    create table(:external_sources, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false
      add :source_type, :string
      add :base_url, :string
      add :api_version, :string
      add :weight_factor, :float, default: 1.0
      add :active, :boolean, default: true
      add :config, :map, default: %{}
      timestamps()
    end
    
    create unique_index(:external_sources, [:name])
    
    create table(:external_ratings, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      add :rating_type, :string, null: false
      add :value, :float, null: false
      add :scale_min, :float, default: 0.0
      add :scale_max, :float, default: 10.0
      add :sample_size, :integer
      add :metadata, :map, default: %{}
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:external_ratings, [:movie_id])
    create index(:external_ratings, [:source_id])
    create unique_index(:external_ratings, [:movie_id, :source_id, :rating_type])
    
    create table(:external_recommendations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :source_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :recommended_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      add :recommendation_type, :string
      add :score, :float
      add :rank, :integer
      add :algorithm_data, :map, default: %{}
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:external_recommendations, [:source_movie_id])
    create index(:external_recommendations, [:recommended_movie_id])
    create index(:external_recommendations, [:source_id])
    create unique_index(:external_recommendations, [:source_movie_id, :recommended_movie_id, :source_id, :recommendation_type], 
      name: :external_recs_unique_idx)
    
    create table(:external_trending, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_id, references(:external_sources, on_delete: :delete_all), null: false
      add :time_window, :string
      add :rank, :integer
      add :score, :float
      add :region, :string
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create index(:external_trending, [:source_id, :time_window, :fetched_at])
    create index(:external_trending, [:movie_id])
    
    # ========================================
    # CULTURAL AUTHORITIES & LISTS
    # ========================================
    
    # Cultural Authorities Registry
    create table(:cultural_authorities, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :name, :string, null: false
      add :authority_type, :string, null: false  # 'award', 'collection', 'critic', 'platform'
      add :category, :string  # 'film_award', 'streaming_platform', 'museum'
      
      # Trust & Weight
      add :trust_score, :float, default: 0.5
      add :base_weight, :float, default: 1.0
      
      # Metadata
      add :description, :text
      add :homepage, :string
      add :country_code, :string
      add :established_year, :integer
      
      # Data tracking
      add :last_sync_at, :utc_datetime
      add :sync_frequency, :string  # 'daily', 'weekly', 'annual'
      add :data_source, :string  # 'api', 'scraper', 'manual'
      
      timestamps()
    end
    
    create unique_index(:cultural_authorities, [:name])
    create index(:cultural_authorities, [:authority_type])
    create index(:cultural_authorities, [:trust_score])
    
    # Curated Lists & Collections
    create table(:curated_lists, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :authority_id, references(:cultural_authorities, on_delete: :delete_all), null: false
      
      add :name, :string, null: false
      add :list_type, :string  # 'ranked', 'unranked', 'award', 'collection'
      add :year, :integer
      
      # List metadata
      add :total_items, :integer
      add :description, :text
      add :selection_criteria, :text
      
      # Quality indicators
      add :prestige_score, :float
      add :cultural_impact, :float
      
      timestamps()
    end
    
    create unique_index(:curated_lists, [:authority_id, :name, :year])
    create index(:curated_lists, [:list_type])
    create index(:curated_lists, [:year])
    
    # Movie-List Associations
    create table(:movie_list_items, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :list_id, references(:curated_lists, on_delete: :delete_all), null: false
      
      # Position/Award data
      add :rank, :integer
      add :award_category, :string  # 'Best Picture', 'Best Director'
      add :award_result, :string  # 'winner', 'nominee'
      
      # Metadata
      add :year_added, :integer
      add :notes, :text
      
      timestamps()
    end
    
    create unique_index(:movie_list_items, [:movie_id, :list_id, :award_category])
    create index(:movie_list_items, [:list_id])
    create index(:movie_list_items, [:movie_id])
    
    # User-Generated Lists (Crowdsourced)
    create table(:user_lists, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :source_platform, :string, null: false  # 'tmdb', 'letterboxd', 'imdb'
      add :external_list_id, :string
      
      add :name, :string
      add :creator_name, :string
      add :creator_reputation, :float
      
      # List metrics
      add :follower_count, :integer
      add :like_count, :integer
      add :item_count, :integer
      
      # Quality scoring
      add :quality_score, :float
      add :spam_score, :float
      
      timestamps()
    end
    
    create index(:user_lists, [:source_platform, :external_list_id])
    create index(:user_lists, [:quality_score])
    
    # Movie appearances in user lists
    create table(:movie_user_list_appearances, primary_key: false) do
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :platform, :string, null: false
      
      # Aggregate metrics
      add :total_list_appearances, :integer
      add :quality_weighted_appearances, :float
      
      # Breakdown by list themes
      add :genre_specific_lists, :integer
      add :award_related_lists, :integer
      add :cultural_lists, :integer
      
      add :last_calculated, :utc_datetime
      
      timestamps()
    end
    
    create index(:movie_user_list_appearances, [:movie_id, :platform])
    
    # Change Tracking
    create table(:movie_data_changes, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :source_platform, :string, null: false
      
      add :change_type, :string
      add :change_count, :integer
      
      # Temporal data
      add :period_start, :utc_datetime
      add :period_end, :utc_datetime
      
      # Change intensity
      add :change_velocity, :float
      add :unusual_activity, :boolean
      
      timestamps()
    end
    
    create index(:movie_data_changes, [:movie_id, :period_end])
    create index(:movie_data_changes, [:source_platform, :period_end])
    
    # ========================================
    # CRI SCORING
    # ========================================
    
    create table(:cri_scores, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      
      add :score, :float
      add :components, :map
      add :version, :string
      add :calculated_at, :utc_datetime
      
      timestamps()
    end
    
    create index(:cri_scores, [:movie_id])
    create index(:cri_scores, [:calculated_at])
  end
end