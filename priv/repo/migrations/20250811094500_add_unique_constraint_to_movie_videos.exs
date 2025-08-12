defmodule Cinegraph.Repo.Migrations.AddUniqueConstraintToMovieVideos do
  use Ecto.Migration

  def change do
    # Add a proper unique constraint using the existing unique index
    # This makes the ON CONFLICT clause work properly with Ecto
    create unique_index(:movie_videos, [:tmdb_id],
             name: :movie_videos_tmdb_id_constraint,
             comment: "Unique constraint for ON CONFLICT handling"
           )

    # Note: We already have movie_videos_tmdb_id_index as a unique index
    # But Ecto prefers an actual constraint for ON CONFLICT operations
    # The index handles uniqueness, this constraint enables ON CONFLICT
  end
end
