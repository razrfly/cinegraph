defmodule Cinegraph.Repo.Migrations.CreateExternalDataSourcesSchema do
  use Ecto.Migration

  def change do
    # ========================================
    # CULTURAL AUTHORITY REGISTRY
    # ========================================
    
    # Master registry of all cultural authorities/data sources
    create table(:cultural_authorities, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :slug, :string, null: false  # e.g., 'criterion-collection', 'afi-top-100'
      add :name, :string, null: false
      add :full_name, :string
      add :description, :text
      
      # Authority categorization
      add :authority_type, :string, null: false  # 'canonical', 'critical', 'academic', 'crowdsourced', 'algorithmic'
      add :category, :string, null: false  # 'official_list', 'award', 'collection', 'user_list', 'critic_aggregate'
      add :subcategory, :string  # 'film_festival', 'museum', 'streaming_platform', etc.
      
      # Authority weight and trust scoring
      add :base_weight, :float, default: 1.0  # Base weight for CRI calculation
      add :trust_score, :integer  # 1-10 scale
      add :reach_score, :integer  # 1-10 scale (audience size/impact)
      add :prestige_score, :integer  # 1-10 scale
      
      # Organization info
      add :organization_name, :string
      add :country_code, :string
      add :founded_year, :integer
      add :website_url, :string
      add :logo_url, :string
      
      # Data collection metadata
      add :data_source_type, :string  # 'api', 'scraper', 'manual', 'import'
      add :update_frequency, :string  # 'realtime', 'daily', 'weekly', 'monthly', 'annual', 'static'
      add :last_sync_at, :utc_datetime
      add :next_sync_at, :utc_datetime
      
      # Quality control
      add :requires_validation, :boolean, default: false
      add :validation_rules, :map, default: %{}
      add :active, :boolean, default: true
      
      # Additional metadata
      add :metadata, :map, default: %{}
      
      timestamps()
    end
    
    create unique_index(:cultural_authorities, [:slug])
    create index(:cultural_authorities, [:authority_type])
    create index(:cultural_authorities, [:category])
    create index(:cultural_authorities, [:active])
    
    # ========================================
    # CURATED LISTS & COLLECTIONS
    # ========================================
    
    # Master table for all types of lists (official, awards, user-generated)
    create table(:curated_lists, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :authority_id, references(:cultural_authorities, on_delete: :restrict), null: false
      add :external_id, :string  # ID from source system
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :text
      
      # List metadata
      add :list_type, :string, null: false  # 'ranked', 'unranked', 'chronological', 'thematic'
      add :year, :integer  # For annual lists (e.g., "AFI Top 100 of 1998")
      add :edition, :string  # For versioned lists
      add :criteria, :text  # Selection criteria description
      
      # Scope and context
      add :scope, :string  # 'global', 'national', 'genre', 'decade', 'director', etc.
      add :country_code, :string
      add :language_code, :string
      add :genre_focus, :string
      add :time_period_start, :integer  # Year
      add :time_period_end, :integer  # Year
      
      # List stats
      add :total_items, :integer
      add :last_updated_by_source, :date
      
      # Quality metrics
      add :completeness_score, :float  # 0-1, how complete is our data
      add :accuracy_score, :float  # 0-1, based on validation
      add :verification_status, :string  # 'unverified', 'partial', 'verified'
      add :verification_date, :utc_datetime
      add :verified_by, :string  # User or system that verified
      
      # Source metadata
      add :source_url, :text
      add :source_data, :map, default: %{}  # Raw data from source
      
      # Internal metadata
      add :import_status, :string, default: "pending"  # 'pending', 'processing', 'completed', 'failed'
      add :import_errors, {:array, :string}, default: []
      add :last_import_at, :utc_datetime
      
      timestamps()
    end
    
    create unique_index(:curated_lists, [:authority_id, :slug])
    create index(:curated_lists, [:list_type])
    create index(:curated_lists, [:year])
    create index(:curated_lists, [:scope])
    create index(:curated_lists, [:import_status])
    
    # ========================================
    # LIST ITEMS (Movies in Lists)
    # ========================================
    
    create table(:list_items, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :list_id, references(:curated_lists, on_delete: :delete_all), null: false
      add :movie_id, references(:movies, on_delete: :delete_all)  # Nullable for unmatched items
      
      # Item positioning
      add :position, :integer  # For ranked lists
      add :group_name, :string  # For grouped lists (e.g., "1920s", "Horror")
      add :group_position, :integer
      
      # Original data from source (for matching/debugging)
      add :original_title, :string
      add :original_year, :integer
      add :original_director, :string
      add :original_id, :string  # ID in source system
      
      # Matching confidence
      add :match_confidence, :float  # 0-1 confidence score
      add :match_method, :string  # 'exact', 'fuzzy', 'manual', 'unmatched'
      add :match_notes, :text
      
      # Item-specific metadata from source
      add :citation, :text  # Why this movie is on the list
      add :notes, :text  # Additional notes from the list
      add :metadata, :map, default: %{}
      
      # Validation
      add :validated, :boolean, default: false
      add :validated_at, :utc_datetime
      add :validation_notes, :text
      
      timestamps()
    end
    
    create index(:list_items, [:list_id])
    create index(:list_items, [:movie_id])
    create unique_index(:list_items, [:list_id, :position], where: "position IS NOT NULL")
    create index(:list_items, [:match_confidence])
    create index(:list_items, [:match_method])
    
    # ========================================
    # AWARDS & HONORS
    # ========================================
    
    create table(:award_ceremonies, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :authority_id, references(:cultural_authorities, on_delete: :restrict), null: false
      add :name, :string, null: false  # "Academy Awards", "Cannes Film Festival"
      add :year, :integer, null: false
      add :ceremony_date, :date
      add :location, :string
      
      # Ceremony metadata
      add :edition_number, :integer  # e.g., "95th Academy Awards"
      add :theme, :string
      add :host, :string
      
      # Import metadata
      add :source_url, :text
      add :import_status, :string, default: "pending"
      add :last_import_at, :utc_datetime
      
      timestamps()
    end
    
    create unique_index(:award_ceremonies, [:authority_id, :year])
    create index(:award_ceremonies, [:year])
    
    create table(:award_categories, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :ceremony_id, references(:award_ceremonies, on_delete: :delete_all), null: false
      add :name, :string, null: false  # "Best Picture", "Palme d'Or"
      add :category_type, :string  # 'film', 'person', 'technical'
      add :description, :text
      add :display_order, :integer
      
      timestamps()
    end
    
    create index(:award_categories, [:ceremony_id])
    create unique_index(:award_categories, [:ceremony_id, :name])
    
    create table(:award_nominations, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :category_id, references(:award_categories, on_delete: :delete_all), null: false
      add :movie_id, references(:movies, on_delete: :delete_all)
      add :person_id, references(:people, on_delete: :delete_all)
      
      # Nomination details
      add :nominee_name, :string  # For unmatched or group nominations
      add :nominee_role, :string  # "Producer", "Director", etc.
      add :is_winner, :boolean, default: false
      add :award_name, :string  # Special award name if different
      add :shared_with, {:array, :string}, default: []  # Other nominees for shared awards
      
      # Original data
      add :original_movie_title, :string
      add :original_person_name, :string
      
      # Matching
      add :match_confidence, :float
      add :match_method, :string
      
      timestamps()
    end
    
    create index(:award_nominations, [:category_id])
    create index(:award_nominations, [:movie_id])
    create index(:award_nominations, [:person_id])
    create index(:award_nominations, [:is_winner])
    
    # ========================================
    # CRITIC AGGREGATIONS
    # ========================================
    
    create table(:critic_scores, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :authority_id, references(:cultural_authorities, on_delete: :restrict), null: false
      
      # Scores
      add :critic_score, :float
      add :critic_score_count, :integer
      add :audience_score, :float
      add :audience_score_count, :integer
      add :metascore, :integer  # For Metacritic specifically
      
      # Additional metrics
      add :fresh_count, :integer  # For RT
      add :rotten_count, :integer  # For RT
      add :average_rating, :float
      add :top_critics_score, :float
      add :verified_audience_score, :float
      
      # Context
      add :score_date, :date  # When score was captured
      add :consensus, :text  # Critical consensus text
      
      # Source data
      add :source_url, :text
      add :raw_data, :map, default: %{}
      
      add :fetched_at, :utc_datetime
      timestamps()
    end
    
    create unique_index(:critic_scores, [:movie_id, :authority_id])
    create index(:critic_scores, [:authority_id])
    create index(:critic_scores, [:score_date])
    
    # ========================================
    # CULTURAL REFERENCES & CITATIONS
    # ========================================
    
    create table(:cultural_references, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :authority_id, references(:cultural_authorities, on_delete: :restrict)
      
      # Reference details
      add :reference_type, :string, null: false  # 'academic_paper', 'syllabus', 'exhibition', 'retrospective', 'homage'
      add :title, :string
      add :description, :text
      add :context, :text  # How the movie is referenced
      
      # Source information
      add :source_name, :string
      add :source_type, :string  # 'university', 'museum', 'publication'
      add :publication_date, :date
      add :author, :string
      add :url, :text
      
      # Academic specific
      add :doi, :string
      add :citation_count, :integer
      add :journal_name, :string
      
      # Influence metrics
      add :influence_score, :float  # Calculated based on source prestige
      add :verified, :boolean, default: false
      
      timestamps()
    end
    
    create index(:cultural_references, [:movie_id])
    create index(:cultural_references, [:reference_type])
    create index(:cultural_references, [:publication_date])
    
    # ========================================
    # STREAMING & DISTRIBUTION REACH
    # ========================================
    
    create table(:distribution_windows, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      
      # Window details
      add :window_type, :string  # 'theatrical', 'streaming', 'physical', 'broadcast'
      add :start_date, :date
      add :end_date, :date
      add :territories, {:array, :string}, default: []
      
      # Platform/distributor
      add :platform_name, :string
      add :platform_tier, :string  # 'premium', 'standard', 'free'
      add :exclusivity, :string  # 'exclusive', 'non-exclusive'
      
      # Performance metrics
      add :availability_score, :float  # How widely available
      add :prominence_score, :float  # How prominently featured
      
      timestamps()
    end
    
    create index(:distribution_windows, [:movie_id])
    create index(:distribution_windows, [:window_type])
    create index(:distribution_windows, [:start_date, :end_date])
    
    # ========================================
    # DATA QUALITY & SANITIZATION
    # ========================================
    
    create table(:data_quality_issues, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :entity_type, :string, null: false  # 'list_item', 'award_nomination', etc.
      add :entity_id, :bigint, null: false
      add :issue_type, :string, null: false  # 'missing_match', 'low_confidence', 'data_conflict'
      add :severity, :string  # 'critical', 'warning', 'info'
      add :description, :text
      add :suggested_action, :text
      add :auto_fixable, :boolean, default: false
      add :resolved, :boolean, default: false
      add :resolved_at, :utc_datetime
      add :resolved_by, :string
      add :resolution_notes, :text
      
      timestamps()
    end
    
    create index(:data_quality_issues, [:entity_type, :entity_id])
    create index(:data_quality_issues, [:issue_type])
    create index(:data_quality_issues, [:resolved])
    
    # ========================================
    # IMPORT JOBS & AUDIT LOG
    # ========================================
    
    create table(:import_jobs, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :authority_id, references(:cultural_authorities, on_delete: :restrict)
      add :job_type, :string  # 'full_sync', 'incremental', 'single_list'
      add :target_type, :string  # 'lists', 'awards', 'scores'
      add :target_id, :bigint  # Specific list/ceremony ID if applicable
      
      # Job execution
      add :status, :string, default: "pending"  # 'pending', 'running', 'completed', 'failed'
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error_message, :text
      add :error_details, :map, default: %{}
      
      # Job results
      add :items_processed, :integer, default: 0
      add :items_created, :integer, default: 0
      add :items_updated, :integer, default: 0
      add :items_failed, :integer, default: 0
      add :match_stats, :map, default: %{}  # Confidence distribution, methods used
      
      # Configuration used
      add :config, :map, default: %{}
      
      timestamps()
    end
    
    create index(:import_jobs, [:authority_id])
    create index(:import_jobs, [:status])
    create index(:import_jobs, [:started_at])
    
    # ========================================
    # COMPOSITE SCORING WEIGHTS
    # ========================================
    
    # Dynamic weight adjustments for authorities based on context
    create table(:authority_weight_adjustments, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :authority_id, references(:cultural_authorities, on_delete: :restrict), null: false
      add :context_type, :string  # 'genre', 'decade', 'country', 'global'
      add :context_value, :string  # e.g., 'horror', '1960s', 'JP'
      add :weight_multiplier, :float, null: false
      add :reason, :text
      add :effective_from, :date
      add :effective_until, :date
      
      timestamps()
    end
    
    create index(:authority_weight_adjustments, [:authority_id])
    create index(:authority_weight_adjustments, [:context_type, :context_value])
    create unique_index(:authority_weight_adjustments, [:authority_id, :context_type, :context_value])
  end
end