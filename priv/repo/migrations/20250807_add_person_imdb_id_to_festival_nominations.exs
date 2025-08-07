defmodule Cinegraph.Repo.Migrations.AddPersonImdbIdToFestivalNominations do
  use Ecto.Migration

  def change do
    alter table(:festival_nominations) do
      # Store person IMDb IDs for nominations where person doesn't exist yet
      # This allows us to create nominations before people are imported
      add :person_imdb_ids, {:array, :string}, default: []
      add :person_name, :string  # Also store name for reference
    end

    # Index for finding pending nominations by person IMDb IDs
    create index(:festival_nominations, [:person_imdb_ids], using: :gin)
    
    # Update the CHECK constraint to allow either movie_id OR movie_imdb_id
    # and similarly allow person_id to be null when we have person_imdb_ids
    execute """
      ALTER TABLE festival_nominations 
      DROP CONSTRAINT IF EXISTS must_have_nominee
    """, """
      ALTER TABLE festival_nominations 
      ADD CONSTRAINT must_have_nominee 
      CHECK (movie_id IS NOT NULL OR movie_imdb_id IS NOT NULL)
    """
    
    # The new constraint should already allow for pending person nominations
    # since person_id was already nullable
  end
end