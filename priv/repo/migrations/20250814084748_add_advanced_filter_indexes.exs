defmodule Cinegraph.Repo.Migrations.AddAdvancedFilterIndexes do
  use Ecto.Migration

  def change do
    # Award filtering indexes
    create_if_not_exists index(:festival_nominations, [:movie_id, :won])
    create_if_not_exists index(:festival_nominations, [:movie_id, :category_id])
    create_if_not_exists index(:festival_nominations, [:ceremony_id])
    create_if_not_exists index(:festival_categories, [:organization_id, :category_type])
    create_if_not_exists index(:festival_ceremonies, [:organization_id, :year])

    # Rating filtering indexes
    create_if_not_exists index(:external_metrics, [:movie_id, :source, :metric_type])
    create_if_not_exists index(:external_metrics, [:source, :metric_type])

    # People filtering indexes
    create_if_not_exists index(:movie_credits, [:person_id, :job])
    create_if_not_exists index(:movie_credits, [:movie_id, :person_id])
    create_if_not_exists index(:movie_credits, [:movie_id, :credit_type])
    create_if_not_exists index(:movie_credits, [:person_id, :credit_type])

    # Metric scores indexes (if using the metric_scores table)
    # create_if_not_exists index(:metric_scores, [:movie_id, :profile_id])
    # create_if_not_exists index(:metric_scores, [:profile_id, :score])

    # General movie filtering performance
    create_if_not_exists index(:movies, [:release_date])
    create_if_not_exists index(:movies, [:runtime])
    create_if_not_exists index(:movies, [:original_language])
  end
end
