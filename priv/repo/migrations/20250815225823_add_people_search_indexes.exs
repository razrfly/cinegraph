defmodule Cinegraph.Repo.Migrations.AddPeopleSearchIndexes do
  use Ecto.Migration

  def change do
    # Add indexes for better people search performance
    create_if_not_exists index(:people, ["LOWER(name) varchar_pattern_ops"], name: :people_name_lower_pattern_idx)
    create_if_not_exists index(:people, [:popularity], name: :people_popularity_idx)
    
    # Add indexes for movie credits filtering by person and role
    create_if_not_exists index(:movie_credits, [:person_id, :job], name: :movie_credits_person_job_idx)
    create_if_not_exists index(:movie_credits, [:person_id, :credit_type], name: :movie_credits_person_type_idx)
    create_if_not_exists index(:movie_credits, [:movie_id, :person_id], name: :movie_credits_movie_person_idx)
    
    # Composite index for efficient role-based filtering
    create_if_not_exists index(:movie_credits, [:person_id, :movie_id, :job], name: :movie_credits_person_movie_job_idx)
  end
end
