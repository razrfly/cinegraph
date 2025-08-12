defmodule Cinegraph.Repo.Migrations.AddCreditBasedPersonLinkingIndexes do
  use Ecto.Migration

  def up do
    # Index for finding people with credits (used in credit-based person linking)
    # This will speed up the query: people -> join credits
    create_if_not_exists index(:movie_credits, [:person_id])
    
    # Index for people name lookups (used for similarity matching)
    # This will speed up queries that filter on people.name
    create_if_not_exists index(:people, [:name])
    
    # Index for people IMDb ID lookups (already exists but ensure it's there)
    create_if_not_exists index(:people, [:imdb_id])
    
    # Composite index for festival nominations person linking
    # This will speed up queries checking if nominations exist
    create_if_not_exists index(:festival_nominations, [:ceremony_id, :category_id, :movie_id])
    
    # Index for festival nominations with person_id NULL (to find unlinked nominations)
    create_if_not_exists index(:festival_nominations, [:person_id], where: "person_id IS NULL")
  end

  def down do
    # Remove indexes in reverse order
    drop_if_exists index(:festival_nominations, [:person_id], where: "person_id IS NULL")
    drop_if_exists index(:festival_nominations, [:ceremony_id, :category_id, :movie_id])
    drop_if_exists index(:people, [:imdb_id])
    drop_if_exists index(:people, [:name])
    drop_if_exists index(:movie_credits, [:person_id])
  end
end