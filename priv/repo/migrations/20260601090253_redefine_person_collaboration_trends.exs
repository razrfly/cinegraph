defmodule Cinegraph.Repo.Migrations.RedefinePersonCollaborationTrends do
  use Ecto.Migration

  # Replaces the O(n²) correlated-`NOT IN` definition of `person_collaboration_trends`
  # (migration 20250730130132) with the cheap `MIN(year)`-based definition. See
  # GitHub #1018 / #1019 for why the old definition made a full REFRESH run ~19.5h
  # and saturated the shared Postgres connection pool.
  #
  # GUARDED: this rebuilds inline ONLY on small datasets (fresh CI/test/dev DBs),
  # where the build is instant. On production-scale data it is a NO-OP — production
  # is rebuilt out-of-band via
  # `Cinegraph.Maintenance.RebuildCollaborationTrends.run/1`, because a multi-minute
  # `CREATE MATERIALIZED VIEW` inside a synchronous migration would exceed Kamal's
  # `deploy_timeout` (see config/deploy.yml).
  #
  # The SQL below is a FROZEN SNAPSHOT of
  # `Cinegraph.Maintenance.RebuildCollaborationTrends.view_sql/0`. Keep the two in
  # sync if the definition ever changes. (Migrations must not call app code, which
  # may not be loaded during release migrations — hence the inlined copy.)

  @row_threshold 50_000

  def up do
    execute("""
    DO $$
    BEGIN
      IF (SELECT count(*) FROM collaboration_details) < #{@row_threshold} THEN
        DROP MATERIALIZED VIEW IF EXISTS person_collaboration_trends CASCADE;

        CREATE MATERIALIZED VIEW person_collaboration_trends AS
        WITH collab_pairs AS (
          SELECT cd.year, c.person_a_id AS person_id, c.person_b_id AS collaborator_id,
                 cd.movie_id, cd.movie_rating, cd.movie_revenue
          FROM collaborations c
          JOIN collaboration_details cd ON c.id = cd.collaboration_id
          WHERE cd.year IS NOT NULL
          UNION ALL
          SELECT cd.year, c.person_b_id AS person_id, c.person_a_id AS collaborator_id,
                 cd.movie_id, cd.movie_rating, cd.movie_revenue
          FROM collaborations c
          JOIN collaboration_details cd ON c.id = cd.collaboration_id
          WHERE cd.year IS NOT NULL
        ),
        person_year_movies AS (
          SELECT person_id, year, movie_id,
                 MAX(movie_rating)  AS movie_rating,
                 MAX(movie_revenue) AS movie_revenue
          FROM collab_pairs
          GROUP BY person_id, year, movie_id
        ),
        movie_stats AS (
          SELECT person_id, year,
                 COUNT(*)                        AS total_collaborations,
                 AVG(movie_rating)::NUMERIC(3,1) AS avg_rating,
                 SUM(movie_revenue)              AS total_revenue
          FROM person_year_movies
          GROUP BY person_id, year
        ),
        collaborator_stats AS (
          SELECT person_id, year,
                 COUNT(DISTINCT collaborator_id) AS unique_collaborators
          FROM collab_pairs
          GROUP BY person_id, year
        ),
        genre_stats AS (
          SELECT pym.person_id, pym.year,
                 array_agg(DISTINCT mg.genre_id ORDER BY mg.genre_id)
                   FILTER (WHERE mg.genre_id IS NOT NULL) AS genre_ids
          FROM person_year_movies pym
          JOIN movie_genres mg ON mg.movie_id = pym.movie_id
          GROUP BY pym.person_id, pym.year
        ),
        first_seen AS (
          SELECT person_id, collaborator_id, MIN(year) AS first_year
          FROM collab_pairs
          GROUP BY person_id, collaborator_id
        ),
        new_collab_counts AS (
          SELECT person_id, first_year AS year, COUNT(*) AS new_collaborators
          FROM first_seen
          GROUP BY person_id, first_year
        )
        SELECT cs.person_id,
               cs.year,
               cs.unique_collaborators,
               COALESCE(ncc.new_collaborators, 0) AS new_collaborators,
               ms.total_collaborations,
               ms.avg_rating,
               ms.total_revenue,
               COALESCE(gs.genre_ids, ARRAY[]::integer[]) AS genre_ids
        FROM collaborator_stats cs
        JOIN movie_stats ms ON ms.person_id = cs.person_id AND ms.year = cs.year
        LEFT JOIN genre_stats gs ON gs.person_id = cs.person_id AND gs.year = cs.year
        LEFT JOIN new_collab_counts ncc ON ncc.person_id = cs.person_id AND ncc.year = cs.year;

        CREATE UNIQUE INDEX person_collaboration_trends_unique_idx
          ON person_collaboration_trends (person_id, year);
        CREATE INDEX person_collaboration_trends_person_idx
          ON person_collaboration_trends (person_id);
        CREATE INDEX person_collaboration_trends_year_idx
          ON person_collaboration_trends (year);
      END IF;
    END $$;
    """)
  end

  def down do
    # No-op: we never restore the slow O(n²) definition. The view continues to
    # exist with whatever definition is currently installed.
    :ok
  end
end
