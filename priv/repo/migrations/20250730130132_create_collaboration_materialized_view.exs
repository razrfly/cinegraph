defmodule Cinegraph.Repo.Migrations.CreateCollaborationMaterializedView do
  use Ecto.Migration

  def up do
    execute """
    CREATE MATERIALIZED VIEW person_collaboration_trends AS
    WITH yearly_collaborations AS (
      SELECT 
        cd.year,
        c.person_a_id as person_id,
        c.person_b_id as collaborator_id,
        cd.movie_id,
        cd.movie_rating,
        cd.movie_revenue,
        mg.genre_id
      FROM collaborations c
      JOIN collaboration_details cd ON c.id = cd.collaboration_id
      LEFT JOIN movie_genres mg ON cd.movie_id = mg.movie_id
      WHERE cd.year IS NOT NULL
      
      UNION ALL
      
      SELECT 
        cd.year,
        c.person_b_id as person_id,
        c.person_a_id as collaborator_id,
        cd.movie_id,
        cd.movie_rating,
        cd.movie_revenue,
        mg.genre_id
      FROM collaborations c
      JOIN collaboration_details cd ON c.id = cd.collaboration_id
      LEFT JOIN movie_genres mg ON cd.movie_id = mg.movie_id
      WHERE cd.year IS NOT NULL
    ),
    yearly_stats AS (
      SELECT 
        person_id,
        year,
        COUNT(DISTINCT collaborator_id) as unique_collaborators,
        COUNT(DISTINCT movie_id) as total_collaborations,
        AVG(movie_rating)::NUMERIC(3,1) as avg_rating,
        SUM(movie_revenue) as total_revenue,
        array_agg(DISTINCT genre_id ORDER BY genre_id) FILTER (WHERE genre_id IS NOT NULL) as genre_ids
      FROM yearly_collaborations
      GROUP BY person_id, year
    ),
    with_new_collaborators AS (
      SELECT 
        ys.*,
        (
          SELECT COUNT(DISTINCT collaborator_id)
          FROM yearly_collaborations yc2
          WHERE yc2.person_id = ys.person_id
            AND yc2.year = ys.year
            AND yc2.collaborator_id NOT IN (
              SELECT DISTINCT collaborator_id
              FROM yearly_collaborations yc3
              WHERE yc3.person_id = ys.person_id
                AND yc3.year < ys.year
            )
        ) as new_collaborators
      FROM yearly_stats ys
    )
    SELECT 
      person_id,
      year,
      unique_collaborators,
      new_collaborators,
      total_collaborations,
      avg_rating,
      total_revenue,
      genre_ids
    FROM with_new_collaborators
    ORDER BY person_id, year
    """

    # Create indexes for better query performance
    execute "CREATE UNIQUE INDEX person_collaboration_trends_unique_idx ON person_collaboration_trends (person_id, year)"

    execute "CREATE INDEX person_collaboration_trends_person_idx ON person_collaboration_trends (person_id)"

    execute "CREATE INDEX person_collaboration_trends_year_idx ON person_collaboration_trends (year)"
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS person_collaboration_trends"
  end
end
