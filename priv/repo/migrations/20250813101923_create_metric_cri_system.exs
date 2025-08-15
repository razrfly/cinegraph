defmodule Cinegraph.Repo.Migrations.CreateMetricCriSystem do
  use Ecto.Migration

  def change do
    # ========== TABLES ==========

    # 1. Metric definitions - metadata about how to interpret each metric
    create table(:metric_definitions) do
      # e.g., 'imdb_rating', 'oscar_wins'
      add :code, :string, null: false
      add :name, :string, null: false
      add :description, :text

      # Source information
      # 'external_metrics', 'festival_nominations', 'canonical_sources'
      add :source_table, :string, null: false
      # e.g., 'imdb', 'tmdb', 'metacritic' for external_metrics
      add :source_type, :string
      # e.g., 'rating_average', 'metascore'
      add :source_field, :string

      # Category mapping (replaces CRI dimension)
      # 'ratings', 'awards', 'financial', 'cultural'
      add :category, :string, null: false
      # e.g., 'critic_rating', 'audience_rating', 'major_award', 'festival_award'
      add :subcategory, :string

      # Normalization
      # 'linear', 'logarithmic', 'sigmoid', 'boolean', 'custom'
      add :normalization_type, :string, null: false
      # Parameters for normalization
      add :normalization_params, :map, default: %{}
      add :raw_scale_min, :float
      add :raw_scale_max, :float

      # Display information
      # 'percentage', 'score', 'money', 'count', 'boolean'
      add :display_format, :string
      # '%', '/10', '/100', '$', null
      add :display_unit, :string

      # Metadata
      # 0.0 to 1.0
      add :source_reliability, :float, default: 1.0
      add :active, :boolean, default: true

      timestamps()
    end

    create unique_index(:metric_definitions, [:code])
    create index(:metric_definitions, [:source_table])
    create index(:metric_definitions, [:category])
    create index(:metric_definitions, [:subcategory])
    create index(:metric_definitions, [:active])

    # 2. Simplified weight profiles for different scoring strategies
    create table(:metric_weight_profiles) do
      add :name, :string, null: false
      add :description, :text

      # Simple JSON for all weights by metric code
      add :weights, :map, null: false, default: %{}
      # Example: {"imdb_rating": 1.0, "oscar_wins": 2.0, "revenue_worldwide": 0.8}

      # Category multipliers (optional) - applied after individual weights
      add :category_weights, :map,
        default: %{"ratings" => 1.0, "awards" => 1.0, "financial" => 1.0, "cultural" => 1.0}

      # Usage tracking
      add :usage_count, :integer, default: 0
      add :last_used_at, :utc_datetime

      # Status
      add :active, :boolean, default: true
      add :is_default, :boolean, default: false
      # System profiles can't be deleted
      add :is_system, :boolean, default: false

      timestamps()
    end

    create unique_index(:metric_weight_profiles, [:name])
    create index(:metric_weight_profiles, [:active])
    create index(:metric_weight_profiles, [:is_default])

    # Ensure only one default profile
    execute """
              CREATE UNIQUE INDEX only_one_default_profile 
              ON metric_weight_profiles (is_default) 
              WHERE is_default = true
            """,
            "DROP INDEX IF EXISTS only_one_default_profile"

    # Note: metric_scores table removed - scores are calculated on-the-fly
    # The system calculates scores dynamically using SQL queries for better flexibility

    # ========== VIEWS ==========

    # Create a VIEW that aggregates all metric data from existing tables
    # This avoids duplicating data that already exists
    execute """
              CREATE VIEW metric_values_view AS
              
              -- External metrics (IMDb, TMDb, Metacritic, RT)
              SELECT 
                em.movie_id,
                CONCAT(em.source, '_', em.metric_type) as metric_code,
                em.value as raw_value_numeric,
                NULL as raw_value_text,
                em.source as source_type,
                em.fetched_at as observed_at,
                'external_metrics' as source_table
              FROM external_metrics em
              WHERE em.value IS NOT NULL
              
              UNION ALL
              
              -- Festival nominations (Oscars, Cannes, etc.)
              SELECT 
                fn.movie_id,
                CASE 
                  WHEN fo.abbreviation = 'AMPAS' AND fn.won = true THEN 'oscar_wins'
                  WHEN fo.abbreviation = 'AMPAS' AND fn.won = false THEN 'oscar_nominations'
                  WHEN fo.abbreviation = 'CANNES' AND fn.won = true THEN 'cannes_palme_dor'
                  WHEN fo.abbreviation = 'VIFF' AND fn.won = true THEN 'venice_golden_lion'
                  WHEN fo.abbreviation = 'BERLINALE' AND fn.won = true THEN 'berlin_golden_bear'
                  ELSE CONCAT(LOWER(fo.abbreviation), '_', CASE WHEN fn.won THEN 'win' ELSE 'nom' END)
                END as metric_code,
                1 as raw_value_numeric,  -- Count will be aggregated
                CASE WHEN fn.won THEN 'true' ELSE 'false' END as raw_value_text,
                fo.abbreviation as source_type,
                fc.date as observed_at,
                'festival_nominations' as source_table
              FROM festival_nominations fn
              JOIN festival_ceremonies fc ON fn.ceremony_id = fc.id
              JOIN festival_organizations fo ON fc.organization_id = fo.id
              WHERE fn.movie_id IS NOT NULL
              
              UNION ALL
              
              -- Canonical sources (1001 Movies, AFI Top 100, etc.)
              SELECT 
                m.id as movie_id,
                key as metric_code,
                CASE 
                  WHEN value::text = 'true' THEN 1
                  WHEN value::text ~ '^[0-9]+$' THEN value::text::integer
                  ELSE NULL
                END as raw_value_numeric,
                value::text as raw_value_text,
                key as source_type,
                m.updated_at as observed_at,
                'canonical_sources' as source_table
              FROM movies m,
              LATERAL jsonb_each(m.canonical_sources) as sources(key, value)
              WHERE m.canonical_sources IS NOT NULL
            """,
            "DROP VIEW IF EXISTS metric_values_view"

    # ========== FUNCTIONS ==========

    # Function to calculate normalized value based on metric definition
    execute """
              CREATE OR REPLACE FUNCTION normalize_metric_value(
                p_value FLOAT,
                p_normalization_type TEXT,
                p_params JSONB,
                p_min FLOAT,
                p_max FLOAT
              ) RETURNS FLOAT AS $$
              DECLARE
                v_result FLOAT;
              BEGIN
                CASE p_normalization_type
                  WHEN 'linear' THEN
                    IF p_max = p_min OR p_max IS NULL OR p_min IS NULL THEN
                      v_result := 0.0;
                    ELSE
                      v_result := (p_value - p_min) / (p_max - p_min);
                    END IF;
                  
                  WHEN 'logarithmic' THEN
                    v_result := LN(p_value + 1) / LN(COALESCE((p_params->>'threshold')::FLOAT, 1000000) + 1);
                  
                  WHEN 'sigmoid' THEN
                    v_result := 1 / (1 + EXP(-COALESCE((p_params->>'k')::FLOAT, 0.05) * 
                               (COALESCE((p_params->>'midpoint')::FLOAT, 50) - p_value)));
                  
                  WHEN 'boolean' THEN
                    v_result := CASE WHEN p_value > 0 THEN 1.0 ELSE 0.0 END;
                  
                  ELSE
                    v_result := p_value;  -- Custom normalization handled in application
                END CASE;
                
                -- Ensure result is between 0 and 1
                RETURN GREATEST(0.0, LEAST(1.0, v_result));
              END;
              $$ LANGUAGE plpgsql IMMUTABLE;
            """,
            "DROP FUNCTION IF EXISTS normalize_metric_value"
  end
end
