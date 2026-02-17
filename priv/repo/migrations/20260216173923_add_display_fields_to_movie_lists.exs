defmodule Cinegraph.Repo.Migrations.AddDisplayFieldsToMovieLists do
  use Ecto.Migration

  def up do
    alter table(:movie_lists) do
      add :slug, :string
      add :short_name, :string
      add :icon, :string
      add :display_order, :integer, default: 0
    end

    create unique_index(:movie_lists, [:slug])

    # Populate display fields for existing canonical lists
    flush()

    execute """
    UPDATE movie_lists SET slug = '1001-movies', short_name = '1001 Movies', icon = 'film', display_order = 1
    WHERE source_key = '1001_movies'
    """

    execute """
    UPDATE movie_lists SET slug = 'criterion', short_name = 'Criterion', icon = 'sparkles', display_order = 2
    WHERE source_key = 'criterion'
    """

    execute """
    UPDATE movie_lists SET slug = 'sight-sound-2022', short_name = 'Sight & Sound 2022', icon = 'eye', display_order = 3
    WHERE source_key = 'sight_sound_critics_2022'
    """

    execute """
    UPDATE movie_lists SET slug = 'national-film-registry', short_name = 'Film Registry', icon = 'building-library', display_order = 4
    WHERE source_key = 'national_film_registry'
    """
  end

  def down do
    drop index(:movie_lists, [:slug])

    alter table(:movie_lists) do
      remove :slug
      remove :short_name
      remove :icon
      remove :display_order
    end
  end
end
