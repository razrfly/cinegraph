defmodule Cinegraph.Repo.Migrations.CreateAwardImportStatusView do
  use Ecto.Migration

  def change do
    # Create a VIEW that shows ALL known festivals and their expected years,
    # not just what's already imported. This enables gap discovery.
    #
    # Uses festival_events table as the source of truth for which festivals
    # are configured for import.
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
            """,
            "DROP VIEW IF EXISTS award_import_status"
  end
end
