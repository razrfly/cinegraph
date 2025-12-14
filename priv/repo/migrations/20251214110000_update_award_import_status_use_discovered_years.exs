defmodule Cinegraph.Repo.Migrations.UpdateAwardImportStatusUseDiscoveredYears do
  use Ecto.Migration

  def up do
    # Drop the old view
    execute "DROP VIEW IF EXISTS award_import_status"

    # Create updated VIEW that uses discovered_years from festival_events
    # instead of generate_series(founded_year, current_year)
    #
    # This respects actual IMDb data availability:
    # - Handles historical gaps (e.g., Sundance has no 1983 data)
    # - Shows only years that actually exist on IMDb
    # - Falls back to generate_series for festivals without discovered_years
    #
    # Uses LATERAL joins because PostgreSQL doesn't allow set-returning
    # functions (unnest, generate_series) in CASE expressions
    execute """
    CREATE VIEW award_import_status AS
    WITH
    -- Use festival_events as the source of truth for known festivals
    known_festivals AS (
      SELECT
        fe.abbreviation,
        fe.name,
        fe.founded_year as first_year,
        fe.discovered_years,
        fe.years_discovered_at,
        CASE
          WHEN fe.primary_source = 'official' THEN 'oscars.org'
          ELSE 'imdb'
        END as default_source
      FROM festival_events fe
      WHERE fe.active = true
    ),
    -- Generate years for each festival using discovered_years via LATERAL join
    festival_years AS (
      SELECT
        kf.abbreviation,
        kf.name,
        kf.first_year,
        kf.default_source,
        kf.years_discovered_at,
        y.year
      FROM known_festivals kf
      CROSS JOIN LATERAL (
        SELECT unnest(kf.discovered_years) AS year
        WHERE kf.discovered_years IS NOT NULL AND array_length(kf.discovered_years, 1) > 0
        UNION ALL
        SELECT generate_series(kf.first_year, EXTRACT(YEAR FROM CURRENT_DATE)::int) AS year
        WHERE kf.discovered_years IS NULL OR array_length(kf.discovered_years, 1) IS NULL OR array_length(kf.discovered_years, 1) = 0
      ) y
    ),
    -- Get nomination stats per ceremony
    nomination_stats AS (
      SELECT
        fn.ceremony_id,
        COUNT(*) as total_nominations,
        COUNT(fn.movie_id) as matched_movies,
        COUNT(fn.person_id) as matched_people,
        COUNT(CASE WHEN fn.won = true THEN 1 END) as winners
      FROM festival_nominations fn
      GROUP BY fn.ceremony_id
    )
    SELECT
      -- Use organization ID if exists, otherwise generate a unique negative ID from abbreviation hash
      -- Using hashtext() to ensure unique IDs even for abbreviations starting with same letter
      COALESCE(fo.id, -1 * ABS(hashtext(fy.abbreviation) % 1000000)) as organization_id,
      fy.name as organization_name,
      fy.abbreviation,
      fc.id as ceremony_id,
      fy.year,
      fc.date as ceremony_date,
      COALESCE(fc.data_source, fy.default_source) as data_source,
      fc.source_url,
      fc.scraped_at,
      fc.source_metadata,
      COALESCE(ns.total_nominations, 0) as total_nominations,
      COALESCE(ns.matched_movies, 0) as matched_movies,
      COALESCE(ns.matched_people, 0) as matched_people,
      COALESCE(ns.winners, 0) as winners,
      CASE
        WHEN ns.total_nominations IS NULL OR ns.total_nominations = 0 THEN 0
        ELSE ROUND((ns.matched_movies::numeric / ns.total_nominations::numeric) * 100, 1)
      END as movie_match_rate,
      CASE
        -- Check source_metadata for explicit status first (e.g., 'no_data' from 404)
        WHEN fc.source_metadata->>'import_status' = 'no_data' THEN 'no_data'
        WHEN fc.source_metadata->>'import_status' = 'failed' THEN 'failed'
        WHEN fc.id IS NULL THEN 'not_started'
        WHEN fc.scraped_at IS NULL THEN 'pending'
        WHEN ns.total_nominations = 0 OR ns.total_nominations IS NULL THEN 'empty'
        WHEN (ns.matched_movies::numeric / ns.total_nominations::numeric) >= 0.9 THEN 'completed'
        WHEN (ns.matched_movies::numeric / ns.total_nominations::numeric) >= 0.5 THEN 'partial'
        WHEN ns.matched_movies > 0 THEN 'low_match'
        ELSE 'no_matches'
      END as status,
      fy.years_discovered_at,
      fc.inserted_at as created_at,
      fc.updated_at
    FROM festival_years fy
    LEFT JOIN festival_organizations fo
      ON fo.abbreviation = fy.abbreviation
    LEFT JOIN festival_ceremonies fc
      ON fc.organization_id = fo.id AND fc.year = fy.year
    LEFT JOIN nomination_stats ns
      ON ns.ceremony_id = fc.id
    ORDER BY fy.abbreviation, fy.year DESC
    """
  end

  def down do
    # Drop the new view
    execute "DROP VIEW IF EXISTS award_import_status"

    # Restore original view using generate_series
    execute """
    CREATE VIEW award_import_status AS
    WITH
    -- Use festival_events as the source of truth for known festivals
    known_festivals AS (
      SELECT
        fe.abbreviation,
        fe.name,
        fe.founded_year as first_year,
        CASE
          WHEN fe.primary_source = 'official' THEN 'oscars.org'
          ELSE 'imdb'
        END as default_source
      FROM festival_events fe
      WHERE fe.active = true
    ),
    -- Generate all expected years for each festival
    festival_years AS (
      SELECT
        kf.abbreviation,
        kf.name,
        kf.first_year,
        kf.default_source,
        generate_series(kf.first_year, EXTRACT(YEAR FROM CURRENT_DATE)::int) AS year
      FROM known_festivals kf
    ),
    -- Get nomination stats per ceremony
    nomination_stats AS (
      SELECT
        fn.ceremony_id,
        COUNT(*) as total_nominations,
        COUNT(fn.movie_id) as matched_movies,
        COUNT(fn.person_id) as matched_people,
        COUNT(CASE WHEN fn.won = true THEN 1 END) as winners
      FROM festival_nominations fn
      GROUP BY fn.ceremony_id
    )
    SELECT
      -- Use organization ID if exists, otherwise generate a unique negative ID from abbreviation hash
      -- Using hashtext() to ensure unique IDs even for abbreviations starting with same letter
      COALESCE(fo.id, -1 * ABS(hashtext(fy.abbreviation) % 1000000)) as organization_id,
      fy.name as organization_name,
      fy.abbreviation,
      fc.id as ceremony_id,
      fy.year,
      fc.date as ceremony_date,
      COALESCE(fc.data_source, fy.default_source) as data_source,
      fc.source_url,
      fc.scraped_at,
      fc.source_metadata,
      COALESCE(ns.total_nominations, 0) as total_nominations,
      COALESCE(ns.matched_movies, 0) as matched_movies,
      COALESCE(ns.matched_people, 0) as matched_people,
      COALESCE(ns.winners, 0) as winners,
      CASE
        WHEN ns.total_nominations IS NULL OR ns.total_nominations = 0 THEN 0
        ELSE ROUND((ns.matched_movies::numeric / ns.total_nominations::numeric) * 100, 1)
      END as movie_match_rate,
      CASE
        WHEN fc.id IS NULL THEN 'not_started'
        WHEN fc.scraped_at IS NULL THEN 'pending'
        WHEN ns.total_nominations = 0 OR ns.total_nominations IS NULL THEN 'empty'
        WHEN (ns.matched_movies::numeric / ns.total_nominations::numeric) >= 0.9 THEN 'completed'
        WHEN (ns.matched_movies::numeric / ns.total_nominations::numeric) >= 0.5 THEN 'partial'
        WHEN ns.matched_movies > 0 THEN 'low_match'
        ELSE 'no_matches'
      END as status,
      fc.inserted_at as created_at,
      fc.updated_at
    FROM festival_years fy
    LEFT JOIN festival_organizations fo
      ON fo.abbreviation = fy.abbreviation
    LEFT JOIN festival_ceremonies fc
      ON fc.organization_id = fo.id AND fc.year = fy.year
    LEFT JOIN nomination_stats ns
      ON ns.ceremony_id = fc.id
    ORDER BY fy.abbreviation, fy.year DESC
    """
  end
end
