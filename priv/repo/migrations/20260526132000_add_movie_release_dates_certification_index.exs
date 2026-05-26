defmodule Cinegraph.Repo.Migrations.AddMovieReleaseDatesCertificationIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists index(:movie_release_dates, [:certification],
                           name: :idx_movie_release_dates_certification_not_null,
                           where: "certification IS NOT NULL AND certification <> ''",
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:movie_release_dates, [:certification],
                     name: :idx_movie_release_dates_certification_not_null,
                     concurrently: true
                   )
  end
end
