defmodule Cinegraph.Repo.Migrations.AddMissingFestivalConstraints do
  use Ecto.Migration

  def change do
    # Add unique constraint for festival_nominations that was missing
    create_if_not_exists unique_index(:festival_nominations, [:ceremony_id, :category_id, :movie_id, :person_id], 
           name: :festival_nominations_unique_index)
    
    # Add index for person_id lookups if not exists
    create_if_not_exists index(:festival_nominations, [:person_id])
    
    # Add index for movie_id lookups if not exists
    create_if_not_exists index(:festival_nominations, [:movie_id])
    
    # Add index for ceremony_id if not exists
    create_if_not_exists index(:festival_nominations, [:ceremony_id])
  end
end