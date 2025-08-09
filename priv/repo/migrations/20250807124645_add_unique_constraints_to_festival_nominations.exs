defmodule Cinegraph.Repo.Migrations.AddUniqueConstraintsToFestivalNominations do
  use Ecto.Migration

  def change do
    # Drop any existing problematic indexes first (if they exist)
    drop_if_exists index(:festival_nominations, [:ceremony_id, :category_id, :movie_id])
    
    # Create unique index for person-based nominations (where person_name is not null)
    # This prevents duplicate nominations for the same person in the same category/ceremony/movie
    create unique_index(
      :festival_nominations, 
      [:ceremony_id, :category_id, :movie_id, :person_name],
      name: :festival_nominations_unique_person_idx,
      where: "person_name IS NOT NULL"
    )
    
    # Create unique index for film-based nominations (where person_name is null)
    # This prevents duplicate nominations for film awards in the same category/ceremony/movie
    create unique_index(
      :festival_nominations,
      [:ceremony_id, :category_id, :movie_id],
      name: :festival_nominations_unique_film_idx,
      where: "person_name IS NULL AND movie_id IS NOT NULL"
    )
    
    # Create similar indexes for pending nominations (using movie_imdb_id instead of movie_id)
    create unique_index(
      :festival_nominations,
      [:ceremony_id, :category_id, :movie_imdb_id, :person_name],
      name: :festival_nominations_unique_pending_person_idx,
      where: "person_name IS NOT NULL AND movie_imdb_id IS NOT NULL"
    )
    
    create unique_index(
      :festival_nominations,
      [:ceremony_id, :category_id, :movie_imdb_id],
      name: :festival_nominations_unique_pending_film_idx,
      where: "person_name IS NULL AND movie_imdb_id IS NOT NULL AND movie_id IS NULL"
    )
  end
end