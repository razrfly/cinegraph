defmodule Cinegraph.Repo.Migrations.CreateOscarStatsViews do
  use Ecto.Migration

  def up do
    # Create view for movie Oscar statistics
    execute """
    CREATE VIEW movie_oscar_stats AS
    SELECT 
      movie_id,
      COUNT(*) as nomination_count,
      COUNT(*) FILTER (WHERE won = true) as win_count,
      COUNT(*) FILTER (WHERE oc.is_major = true) as major_nomination_count,
      COUNT(*) FILTER (WHERE won = true AND oc.is_major = true) as major_win_count
    FROM oscar_nominations onom
    JOIN oscar_categories oc ON onom.category_id = oc.id
    WHERE movie_id IS NOT NULL
    GROUP BY movie_id;
    """
    
    # Create view for person Oscar statistics
    execute """
    CREATE VIEW person_oscar_stats AS
    SELECT 
      person_id,
      COUNT(*) as nomination_count,
      COUNT(*) FILTER (WHERE won = true) as win_count
    FROM oscar_nominations
    WHERE person_id IS NOT NULL
    GROUP BY person_id;
    """
  end
  
  def down do
    execute "DROP VIEW IF EXISTS person_oscar_stats;"
    execute "DROP VIEW IF EXISTS movie_oscar_stats;"
  end
end
