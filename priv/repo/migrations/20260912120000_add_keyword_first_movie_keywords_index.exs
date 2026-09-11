defmodule Cinegraph.Repo.Migrations.AddKeywordFirstMovieKeywordsIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:movie_keywords, [:keyword_id, :movie_id],
        name: :movie_keywords_keyword_id_movie_id_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:movie_keywords, [:keyword_id, :movie_id],
        name: :movie_keywords_keyword_id_movie_id_index,
        concurrently: true
      )
    )
  end
end
