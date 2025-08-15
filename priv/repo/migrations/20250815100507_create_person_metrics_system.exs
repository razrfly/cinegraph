defmodule Cinegraph.Repo.Migrations.CreatePersonMetricsSystem do
  use Ecto.Migration

  def up do
    # Create person_metrics table with all constraints
    create table(:person_metrics) do
      add :person_id, references(:people, on_delete: :delete_all), null: false
      add :metric_type, :string, null: false
      add :score, :float, null: false
      add :components, :map, default: %{}
      add :metadata, :map, default: %{}
      add :calculated_at, :utc_datetime, null: false
      add :valid_until, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:person_metrics, [:person_id, :metric_type])
    create index(:person_metrics, [:metric_type])
    create index(:person_metrics, [:score])
    create index(:person_metrics, [:calculated_at])
    
    # Add check constraint for score range
    create constraint(:person_metrics, :score_range, check: "score >= 0 AND score <= 100")

    # Add people category index to metric_definitions
    create index(:metric_definitions, [:category, :subcategory])

    # Create or replace the metric_values_view with person metrics
    # First drop if exists
    execute "DROP VIEW IF EXISTS metric_values_view"
    
    # Create the view - restructured to avoid CTE in UNION
    execute """
    CREATE VIEW metric_values_view AS
      SELECT 
        em.movie_id,
        CONCAT(em.source, '_', em.metric_type) as metric_code,
        em.value as raw_value_numeric,
        em.text_value as raw_value_text,
        em.source as source_type,
        em.updated_at as observed_at,
        'external_metrics' as source_table
      FROM external_metrics em
      WHERE em.movie_id IS NOT NULL

      UNION ALL

      SELECT 
        fn.movie_id,
        'award_wins' as metric_code,
        COUNT(CASE WHEN fn.won = true THEN 1 END) as raw_value_numeric,
        fo.name as raw_value_text,
        'festival' as source_type,
        MAX(fn.updated_at) as observed_at,
        'festival_nominations' as source_table
      FROM festival_nominations fn
      JOIN festival_ceremonies fc ON fn.ceremony_id = fc.id
      JOIN festival_organizations fo ON fc.organization_id = fo.id
      WHERE fn.movie_id IS NOT NULL
      GROUP BY fn.movie_id, fo.name

      UNION ALL

      SELECT 
        fn.movie_id,
        'award_nominations' as metric_code,
        COUNT(*) as raw_value_numeric,
        fo.name as raw_value_text,
        'festival' as source_type,
        MAX(fn.updated_at) as observed_at,
        'festival_nominations' as source_table
      FROM festival_nominations fn
      JOIN festival_ceremonies fc ON fn.ceremony_id = fc.id
      JOIN festival_organizations fo ON fc.organization_id = fo.id
      WHERE fn.movie_id IS NOT NULL
      GROUP BY fn.movie_id, fo.name

      UNION ALL

      SELECT 
        m.id as movie_id,
        'canonical_presence' as metric_code,
        jsonb_array_length(jsonb_object_keys(COALESCE(m.canonical_sources, '{}'::jsonb))::jsonb) as raw_value_numeric,
        array_to_string(ARRAY(SELECT jsonb_object_keys(m.canonical_sources)), ', ') as raw_value_text,
        'canonical' as source_type,
        m.updated_at as observed_at,
        'movies' as source_table
      FROM movies m
      WHERE m.canonical_sources IS NOT NULL 
        AND m.canonical_sources != '{}'::jsonb

      UNION ALL

      -- Person quality scores (aggregated per movie)
      SELECT 
        pms.movie_id,
        'person_quality_score' as metric_code,
        pms.avg_score as raw_value_numeric,
        'quality_score' as raw_value_text,
        'person_metrics' as source_type,
        pms.latest_calc as observed_at,
        'person_metrics' as source_table
      FROM (
        SELECT 
          mc.movie_id,
          AVG(pm.score) as avg_score,
          MAX(pm.calculated_at) as latest_calc
        FROM movie_credits mc
        JOIN (
          -- Get latest score per person
          SELECT DISTINCT ON (person_id)
            person_id, 
            score, 
            metric_type, 
            calculated_at
          FROM person_metrics
          WHERE metric_type = 'quality_score'
            AND score IS NOT NULL
          ORDER BY person_id, calculated_at DESC
        ) pm ON pm.person_id = mc.person_id
        WHERE mc.movie_id IS NOT NULL
        GROUP BY mc.movie_id
      ) pms
    """
  end

  def down do
    # Drop the view
    execute "DROP VIEW IF EXISTS metric_values_view"
    
    # Drop indexes
    drop index(:metric_definitions, [:category, :subcategory])
    
    # Drop the person_metrics table
    drop table(:person_metrics)
  end
end