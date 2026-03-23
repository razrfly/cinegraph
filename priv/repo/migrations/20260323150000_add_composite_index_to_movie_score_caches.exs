defmodule Cinegraph.Repo.Migrations.AddCompositeIndexToMovieScoreCaches do
  use Ecto.Migration

  def change do
    # Composite index for list_movies_by_disparity_category/2:
    # WHERE disparity_category = ? ORDER BY disparity_score DESC, id ASC
    create index(:movie_score_caches, [:disparity_category, :disparity_score],
             name: :idx_score_caches_category_score
           )
  end
end
