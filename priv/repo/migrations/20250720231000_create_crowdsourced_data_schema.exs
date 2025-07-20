defmodule Cinegraph.Repo.Migrations.CreateCrowdsourcedDataSchema do
  use Ecto.Migration

  def change do
    # ========================================
    # USER-GENERATED LISTS FROM TMDB & OTHERS
    # ========================================
    
    # User profiles from various platforms
    create table(:external_user_profiles, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :platform, :string, null: false  # 'tmdb', 'letterboxd', 'imdb'
      add :external_user_id, :string, null: false
      add :username, :string
      add :display_name, :string
      
      # User credibility metrics
      add :follower_count, :integer
      add :list_count, :integer
      add :review_count, :integer
      add :member_since, :date
      add :verified_status, :boolean, default: false
      
      # Calculated trust score
      add :trust_score, :float  # 0-1, based on activity, followers, quality
      add :influence_score, :float  # 0-1, based on reach and engagement
      
      # Profile metadata
      add :bio, :text
      add :location, :string
      add :favorite_genres, {:array, :string}, default: []
      add :profile_url, :string
      add :avatar_url, :string
      
      # Activity tracking
      add :last_activity_at, :utc_datetime
      add :activity_level, :string  # 'inactive', 'casual', 'regular', 'power'
      
      timestamps()
    end
    
    create unique_index(:external_user_profiles, [:platform, :external_user_id])
    create index(:external_user_profiles, [:trust_score])
    create index(:external_user_profiles, [:influence_score])
    
    # User-generated lists with quality scoring
    create table(:user_generated_lists, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :user_profile_id, references(:external_user_profiles, on_delete: :restrict)
      add :platform, :string, null: false
      add :external_list_id, :string, null: false
      add :name, :string, null: false
      add :description, :text
      
      # List metadata
      add :item_count, :integer
      add :created_date, :date
      add :last_updated, :date
      add :privacy_status, :string  # 'public', 'private', 'friends'
      add :list_type, :string  # 'favorites', 'watched', 'custom', 'ranked'
      
      # Engagement metrics
      add :like_count, :integer, default: 0
      add :comment_count, :integer, default: 0
      add :follower_count, :integer, default: 0
      add :view_count, :integer, default: 0
      add :share_count, :integer, default: 0
      
      # Quality indicators
      add :has_descriptions, :boolean  # Do items have notes?
      add :average_item_popularity, :float  # How mainstream/obscure
      add :diversity_score, :float  # Genre/era/country diversity
      add :curation_score, :float  # Overall quality score
      add :spam_score, :float  # Likelihood of being spam/low-quality
      
      # List categorization
      add :detected_theme, :string  # AI-detected theme
      add :detected_genres, {:array, :string}, default: []
      add :detected_era, :string  # 'classic', 'modern', 'mixed'
      
      # Import status
      add :import_status, :string, default: "pending"
      add :last_import_at, :utc_datetime
      add :import_priority, :integer  # Based on quality and engagement
      
      # Source data
      add :source_url, :text
      add :raw_metadata, :map, default: %{}
      
      timestamps()
    end
    
    create unique_index(:user_generated_lists, [:platform, :external_list_id])
    create index(:user_generated_lists, [:user_profile_id])
    create index(:user_generated_lists, [:curation_score])
    create index(:user_generated_lists, [:import_status])
    create index(:user_generated_lists, [:import_priority])
    
    # Items in user lists with engagement data
    create table(:user_list_items, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :list_id, references(:user_generated_lists, on_delete: :delete_all), null: false
      add :movie_id, references(:movies, on_delete: :delete_all)
      
      # Position and grouping
      add :position, :integer
      add :date_added, :utc_datetime
      
      # User's notes/ratings
      add :user_rating, :float
      add :user_notes, :text
      add :tags, {:array, :string}, default: []
      
      # Original data for matching
      add :original_title, :string
      add :original_year, :integer
      add :external_movie_id, :string
      
      # Matching
      add :match_confidence, :float
      add :match_method, :string
      
      timestamps()
    end
    
    create index(:user_list_items, [:list_id])
    create index(:user_list_items, [:movie_id])
    create index(:user_list_items, [:date_added])
    
    # ========================================
    # SOCIAL MEDIA & MEME TRACKING
    # ========================================
    
    create table(:social_media_mentions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :platform, :string, null: false  # 'twitter', 'reddit', 'tiktok'
      add :mention_type, :string  # 'quote', 'reference', 'meme', 'discussion'
      
      # Content details
      add :content_snippet, :text  # Relevant excerpt
      add :full_content_url, :text
      add :author_handle, :string
      add :author_followers, :integer
      
      # Engagement metrics
      add :like_count, :integer
      add :share_count, :integer
      add :comment_count, :integer
      add :view_count, :integer
      add :engagement_rate, :float
      
      # Virality indicators
      add :is_viral, :boolean, default: false
      add :virality_score, :float
      add :reached_audience, :integer  # Estimated reach
      
      # Sentiment and context
      add :sentiment, :string  # 'positive', 'negative', 'neutral', 'mixed'
      add :sentiment_score, :float  # -1 to 1
      add :context_tags, {:array, :string}, default: []  # 'nostalgic', 'critical', 'humorous'
      
      # Temporal data
      add :posted_at, :utc_datetime
      add :captured_at, :utc_datetime
      add :peak_engagement_at, :utc_datetime
      
      timestamps()
    end
    
    create index(:social_media_mentions, [:movie_id])
    create index(:social_media_mentions, [:platform])
    create index(:social_media_mentions, [:posted_at])
    create index(:social_media_mentions, [:virality_score])
    
    # Meme tracking
    create table(:meme_references, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      
      # Meme identification
      add :meme_name, :string
      add :meme_description, :text
      add :knowyourmeme_url, :text
      add :first_appearance, :date
      add :peak_popularity, :date
      
      # Origin details
      add :source_scene, :string  # Description of scene/quote
      add :source_timestamp, :string  # Where in the movie
      add :original_quote, :text
      add :common_variations, {:array, :string}, default: []
      
      # Usage metrics
      add :usage_count, :integer  # Tracked instances
      add :platform_breakdown, :map, default: %{}  # Usage per platform
      add :longevity_score, :float  # How long it stayed relevant
      add :cultural_impact_score, :float
      
      # Evolution tracking
      add :evolution_stages, :map, default: %{}  # How the meme changed over time
      add :related_memes, {:array, :string}, default: []
      
      timestamps()
    end
    
    create index(:meme_references, [:movie_id])
    create index(:meme_references, [:first_appearance])
    create index(:meme_references, [:cultural_impact_score])
    
    # ========================================
    # AGGREGATED SOCIAL SIGNALS
    # ========================================
    
    # Daily/weekly aggregated social metrics
    create table(:social_metrics_snapshots, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :snapshot_date, :date, null: false
      add :period_type, :string  # 'daily', 'weekly', 'monthly'
      
      # Mention volumes
      add :total_mentions, :integer
      add :unique_authors, :integer
      add :platform_breakdown, :map, default: %{}
      
      # Engagement totals
      add :total_engagement, :bigint
      add :average_engagement_rate, :float
      
      # Sentiment summary
      add :positive_mentions, :integer
      add :negative_mentions, :integer
      add :neutral_mentions, :integer
      add :average_sentiment, :float
      
      # Trend indicators
      add :trend_direction, :string  # 'rising', 'falling', 'stable'
      add :trend_velocity, :float  # Rate of change
      add :is_trending, :boolean, default: false
      add :trend_triggers, {:array, :string}, default: []  # What caused the trend
      
      # Context
      add :notable_events, {:array, :string}, default: []  # Related events
      add :top_hashtags, {:array, :string}, default: []
      add :top_quotes, {:array, :string}, default: []
      
      timestamps()
    end
    
    create unique_index(:social_metrics_snapshots, [:movie_id, :snapshot_date, :period_type])
    create index(:social_metrics_snapshots, [:snapshot_date])
    create index(:social_metrics_snapshots, [:is_trending])
    
    # ========================================
    # COMMUNITY REVIEWS & DISCUSSIONS
    # ========================================
    
    create table(:community_reviews, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :platform, :string, null: false  # 'letterboxd', 'imdb', 'reddit'
      add :external_review_id, :string
      
      # Review content
      add :author_name, :string
      add :author_profile_url, :text
      add :rating, :float
      add :review_text, :text
      add :review_date, :date
      add :is_spoiler, :boolean, default: false
      
      # Review quality
      add :word_count, :integer
      add :helpfulness_score, :float  # Based on upvotes/likes
      add :quality_score, :float  # Our assessment
      add :is_featured, :boolean, default: false  # Platform featured
      
      # Engagement
      add :like_count, :integer
      add :comment_count, :integer
      add :report_count, :integer
      
      # Analysis
      add :sentiment_score, :float
      add :themes_mentioned, {:array, :string}, default: []
      add :aspects_praised, {:array, :string}, default: []
      add :aspects_criticized, {:array, :string}, default: []
      
      timestamps()
    end
    
    create index(:community_reviews, [:movie_id])
    create index(:community_reviews, [:platform])
    create index(:community_reviews, [:review_date])
    create index(:community_reviews, [:quality_score])
    
    # ========================================
    # INFLUENCE TRACKING
    # ========================================
    
    create table(:movie_influences, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :influenced_movie_id, references(:movies, on_delete: :delete_all), null: false
      add :influencer_movie_id, references(:movies, on_delete: :delete_all), null: false
      
      # Influence details
      add :influence_type, :string  # 'homage', 'reference', 'remake', 'spiritual_successor'
      add :influence_strength, :float  # 0-1 score
      add :evidence_type, :string  # 'director_stated', 'critic_noted', 'audience_recognized'
      
      # Evidence
      add :source_quotes, {:array, :text}, default: []
      add :source_urls, {:array, :text}, default: []
      add :specific_elements, {:array, :string}, default: []  # What was influenced
      
      # Validation
      add :confidence_score, :float
      add :verified, :boolean, default: false
      add :verified_by, :string
      add :verification_notes, :text
      
      timestamps()
    end
    
    create index(:movie_influences, [:influenced_movie_id])
    create index(:movie_influences, [:influencer_movie_id])
    create index(:movie_influences, [:influence_type])
    create unique_index(:movie_influences, [:influenced_movie_id, :influencer_movie_id, :influence_type])
    
    # ========================================
    # DATA SANITIZATION & VALIDATION
    # ========================================
    
    # Track spam/low-quality content
    create table(:content_moderation_flags, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :content_type, :string, null: false  # 'user_list', 'review', 'social_mention'
      add :content_id, :bigint, null: false
      add :flag_type, :string  # 'spam', 'bot', 'low_quality', 'offensive'
      add :flag_reason, :text
      add :confidence, :float
      add :flagged_by, :string  # 'auto', 'user', 'moderator'
      add :reviewed, :boolean, default: false
      add :action_taken, :string  # 'removed', 'downweighted', 'approved'
      add :reviewed_at, :utc_datetime
      add :reviewed_by, :string
      
      timestamps()
    end
    
    create index(:content_moderation_flags, [:content_type, :content_id])
    create index(:content_moderation_flags, [:flag_type])
    create index(:content_moderation_flags, [:reviewed])
    
    # Aggregate quality scores for crowdsourced data
    create table(:crowdsource_quality_scores, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :movie_id, references(:movies, on_delete: :delete_all), null: false
      add :metric_type, :string  # 'list_inclusions', 'review_sentiment', 'social_buzz'
      
      # Volume metrics
      add :total_mentions, :integer
      add :unique_sources, :integer
      add :quality_weighted_mentions, :float  # Weighted by source quality
      
      # Quality metrics
      add :average_source_quality, :float
      add :consistency_score, :float  # How consistent is the sentiment
      add :diversity_score, :float  # Diversity of sources
      
      # Temporal metrics
      add :recency_weighted_score, :float  # Recent mentions weighted higher
      add :longevity_score, :float  # How long has it been discussed
      
      # Final scores
      add :raw_score, :float
      add :normalized_score, :float  # 0-1
      add :percentile_rank, :float  # Among all movies
      
      add :calculated_at, :utc_datetime
      timestamps()
    end
    
    create unique_index(:crowdsource_quality_scores, [:movie_id, :metric_type])
    create index(:crowdsource_quality_scores, [:normalized_score])
    create index(:crowdsource_quality_scores, [:calculated_at])
  end
end