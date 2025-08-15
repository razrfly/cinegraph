defmodule Cinegraph.Repo.Migrations.AddPersonMetricsToMetricValuesView do
  use Ecto.Migration

  def change do
    # Drop the existing view
    execute "DROP VIEW IF EXISTS metric_values_view", ""

    # Recreate the view with person metrics included
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
              
              UNION ALL
              
              -- Person quality scores (Directors, Actors, Writers, etc.)
              SELECT 
                movie_credits.movie_id,
                'person_quality_score' as metric_code,
                pm.score as raw_value_numeric,
                pm.metric_type as raw_value_text,
                'person_metrics' as source_type,
                pm.calculated_at as observed_at,
                'person_metrics' as source_table
              FROM person_metrics pm
              JOIN movie_credits ON pm.person_id = movie_credits.person_id
              WHERE pm.metric_type = 'quality_score' 
                AND pm.score IS NOT NULL
                AND movie_credits.movie_id IS NOT NULL
            """,
            "DROP VIEW IF EXISTS metric_values_view"
  end
end
