defmodule Cinegraph.Repo.Migrations.Add1001MoviesPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Index for faster 1001 Movies queries
    create index(:movies, ["(canonical_sources -> '1001_movies')"], 
           using: :gin, 
           name: :idx_movies_canonical_1001)
    
    # Index for decade-based queries
    create index(:movies, ["DATE_PART('decade', release_date)"], 
           name: :idx_movies_release_decade)
    
    # Composite index for 1001 movies with release dates
    create index(:movies, [:release_date], 
           where: "canonical_sources ? '1001_movies'",
           name: :idx_1001_movies_release_date)
  end
end
