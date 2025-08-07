defmodule Cinegraph.Repo.Migrations.AddMovieImdbIdToFestivalNominations do
  use Ecto.Migration

  def change do
    alter table(:festival_nominations) do
      # Store IMDb ID for nominations where movie doesn't exist yet
      # This allows us to create nominations before movies are imported
      add :movie_imdb_id, :string
      add :movie_title, :string  # Also store title for reference
    end

    # Index for finding pending nominations by IMDb ID
    create index(:festival_nominations, [:movie_imdb_id])
    
    # Allow movie_id to be null temporarily while movie is being created
    drop constraint(:festival_nominations, :festival_nominations_movie_id_fkey)
    
    alter table(:festival_nominations) do
      modify :movie_id, references(:movies, on_delete: :delete_all), null: true
    end
  end
end