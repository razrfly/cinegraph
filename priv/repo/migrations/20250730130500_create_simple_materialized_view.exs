defmodule Cinegraph.Repo.Migrations.CreateSimpleMaterializedView do
  use Ecto.Migration

  def up do
    # Create a simpler materialized view that's more performant
    execute """
    CREATE MATERIALIZED VIEW IF NOT EXISTS person_collaboration_trends AS
    SELECT 
      p.person_id,
      p.year,
      COUNT(DISTINCT p.collaborator_id) as unique_collaborators,
      COUNT(DISTINCT p.movie_id) as total_collaborations,
      AVG(p.movie_rating)::NUMERIC(3,1) as avg_rating,
      COALESCE(SUM(p.movie_revenue), 0) as total_revenue,
      0 as new_collaborators, -- Will be updated separately if needed
      ARRAY[]::integer[] as genre_ids -- Will be updated separately if needed
    FROM (
      -- Get all collaborations from person A perspective
      SELECT 
        c.person_a_id as person_id,
        c.person_b_id as collaborator_id,
        cd.movie_id,
        cd.year,
        cd.movie_rating,
        cd.movie_revenue
      FROM collaborations c
      JOIN collaboration_details cd ON c.id = cd.collaboration_id
      WHERE cd.year IS NOT NULL
      
      UNION ALL
      
      -- Get all collaborations from person B perspective
      SELECT 
        c.person_b_id as person_id,
        c.person_a_id as collaborator_id,
        cd.movie_id,
        cd.year,
        cd.movie_rating,
        cd.movie_revenue
      FROM collaborations c
      JOIN collaboration_details cd ON c.id = cd.collaboration_id
      WHERE cd.year IS NOT NULL
    ) p
    GROUP BY p.person_id, p.year
    """
    
    # Create indexes for better query performance
    execute "CREATE UNIQUE INDEX IF NOT EXISTS person_collaboration_trends_unique_idx ON person_collaboration_trends (person_id, year)"
    execute "CREATE INDEX IF NOT EXISTS person_collaboration_trends_person_idx ON person_collaboration_trends (person_id)"
    execute "CREATE INDEX IF NOT EXISTS person_collaboration_trends_year_idx ON person_collaboration_trends (year)"
  end

  def down do
    execute "DROP MATERIALIZED VIEW IF EXISTS person_collaboration_trends"
  end
end