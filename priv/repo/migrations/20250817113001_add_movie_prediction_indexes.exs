defmodule Cinegraph.Repo.Migrations.AddMoviePredictionIndexes do
  use Ecto.Migration

  def change do
    # Index for 2020s movies not on 1001 list (main prediction candidates)
    create index(:movies, [:release_date], 
           where: "NOT (canonical_sources ? '1001_movies') AND release_date >= '2020-01-01'",
           name: :idx_movies_2020s_prediction_candidates)
    
    # Index for director lookups in movie credits
    create index(:movie_credits, [:person_id], 
           where: "credit_type = 'crew' AND department = 'Directing'",
           name: :idx_movie_credits_directors)
    
    # Index for festival nominations with movie and win status
    create index(:festival_nominations, [:movie_id, :won, :category_id],
           name: :idx_festival_nominations_movie_scoring)
    
    # Index for external metrics by movie and source
    create index(:external_metrics, [:movie_id, :source, :metric_type],
           name: :idx_external_metrics_movie_source)
    
    # Index for historical validation queries by decade
    create index(:movies, ["DATE_PART('decade', release_date)", :id],
           where: "canonical_sources ? '1001_movies'",
           name: :idx_movies_1001_by_decade)
  end
end
