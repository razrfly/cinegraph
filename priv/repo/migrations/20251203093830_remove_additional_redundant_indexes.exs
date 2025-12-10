defmodule Cinegraph.Repo.Migrations.RemoveAdditionalRedundantIndexes do
  use Ecto.Migration

  @moduledoc """
  Removes additional redundant database indexes identified by PlanetScale analysis.
  See GitHub Issue #401 for full documentation.

  Summary of removals:
  - movie_credits: 1 redundant index (covered by composite)
  - collaboration_details: 1 redundant index (covered by unique composite)
  - movie_spoken_languages: 1 redundant index (covered by unique composite)
  - movie_release_dates: 1 redundant index (covered by unique composite)
  - movie_production_countries: 1 redundant index (covered by unique composite)
  - movie_genres: 1 redundant index (covered by unique composite)

  Total: 6 indexes removed

  NOT implemented (intentionally skipped):
  - #16: festival_nominations_ceremony_id_category_id_movie_id_index - Keep both regular
         and unique versions as queries may benefit from non-unique index
  - #31: oban_jobs queue index - Oban's composite index already covers queue lookups
  - #32: year extraction index - Existing decade-based indexes serve most use cases
  """

  def up do
    # ============================================
    # movie_credits table (1 redundant index)
    # ============================================

    # Covered by idx_movie_credits_movie_person_type (movie_id, person_id, credit_type, job)
    # PlanetScale issues #21 and #29
    drop_if_exists index(:movie_credits, [:movie_id, :person_id],
                     name: :movie_credits_movie_id_person_id_index
                   )

    # ============================================
    # collaboration_details table (1 redundant index)
    # ============================================

    # Covered by unique composite index on (collaboration_id, movie_id, collaboration_type)
    # PlanetScale issue #7
    drop_if_exists index(:collaboration_details, [:collaboration_id],
                     name: :collaboration_details_collaboration_id_index
                   )

    # ============================================
    # movie_spoken_languages table (1 redundant index)
    # ============================================

    # Covered by movie_spoken_languages_movie_id_spoken_language_id_index
    # PlanetScale issue #6
    drop_if_exists index(:movie_spoken_languages, [:movie_id],
                     name: :movie_spoken_languages_movie_id_index
                   )

    # ============================================
    # movie_release_dates table (1 redundant index)
    # ============================================

    # Covered by movie_release_dates_movie_id_country_code_release_type_index
    # PlanetScale issue #5
    drop_if_exists index(:movie_release_dates, [:movie_id],
                     name: :movie_release_dates_movie_id_index
                   )

    # ============================================
    # movie_production_countries table (1 redundant index)
    # ============================================

    # Covered by movie_production_countries_movie_id_production_country_id_index
    # PlanetScale issue #4
    drop_if_exists index(:movie_production_countries, [:movie_id],
                     name: :movie_production_countries_movie_id_index
                   )

    # ============================================
    # movie_genres table (1 redundant index)
    # ============================================

    # Covered by movie_genres_movie_id_genre_id_index
    # PlanetScale issue #3
    drop_if_exists index(:movie_genres, [:movie_id], name: :movie_genres_movie_id_index)
  end

  def down do
    # Recreate all dropped indexes for rollback

    # movie_credits
    create_if_not_exists index(:movie_credits, [:movie_id, :person_id],
                           name: :movie_credits_movie_id_person_id_index
                         )

    # collaboration_details
    create_if_not_exists index(:collaboration_details, [:collaboration_id],
                           name: :collaboration_details_collaboration_id_index
                         )

    # movie_spoken_languages
    create_if_not_exists index(:movie_spoken_languages, [:movie_id],
                           name: :movie_spoken_languages_movie_id_index
                         )

    # movie_release_dates
    create_if_not_exists index(:movie_release_dates, [:movie_id],
                           name: :movie_release_dates_movie_id_index
                         )

    # movie_production_countries
    create_if_not_exists index(:movie_production_countries, [:movie_id],
                           name: :movie_production_countries_movie_id_index
                         )

    # movie_genres
    create_if_not_exists index(:movie_genres, [:movie_id], name: :movie_genres_movie_id_index)
  end
end
