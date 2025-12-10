defmodule Cinegraph.Repo.Migrations.RemoveRedundantIndexes do
  use Ecto.Migration

  @moduledoc """
  Removes redundant database indexes identified by PlanetScale analysis.
  See GitHub Issue #401 for full documentation.

  Summary of removals:
  - movie_credits: 5 redundant indexes (duplicates and covered indexes)
  - external_metrics: 2 redundant indexes
  - movie_videos: 1 duplicate index
  - movie_recommendations: 1 covered index
  - festival_nominations: 4 redundant indexes
  - festival_ceremonies: 1 covered index
  - metric_definitions: 1 covered index
  - movies: 1 covered index

  Total: 16 indexes removed
  """

  def up do
    # ============================================
    # movie_credits table (5 redundant indexes)
    # ============================================

    # Duplicate of movie_credits_movie_id_person_id_index
    drop_if_exists index(:movie_credits, [:movie_id, :person_id],
                     name: :movie_credits_movie_person_idx
                   )

    # Covered by movie_credits_movie_id_person_id_index and movie_credits_movie_id_credit_type_index
    drop_if_exists index(:movie_credits, [:movie_id], name: :movie_credits_movie_id_index)

    # Duplicate of movie_credits_person_id_job_index
    drop_if_exists index(:movie_credits, [:person_id, :job], name: :movie_credits_person_job_idx)

    # Duplicate of movie_credits_person_id_credit_type_index
    drop_if_exists index(:movie_credits, [:person_id, :credit_type],
                     name: :movie_credits_person_type_idx
                   )

    # Covered by multiple composite indexes starting with person_id
    drop_if_exists index(:movie_credits, [:person_id], name: :movie_credits_person_id_index)

    # Duplicate of movie_credits_movie_person_idx (keeping movie_credits_movie_id_person_id_index)
    # Note: We already dropped movie_credits_movie_person_idx above, so we keep movie_credits_movie_id_person_id_index

    # ============================================
    # external_metrics table (2 redundant indexes)
    # ============================================

    # Covered by external_metrics_movie_id_source_metric_type_index
    drop_if_exists index(:external_metrics, [:movie_id], name: :external_metrics_movie_id_index)

    # Duplicate of external_metrics_movie_source_type_index (unique version)
    drop_if_exists index(:external_metrics, [:movie_id, :source, :metric_type],
                     name: :external_metrics_movie_id_source_metric_type_index
                   )

    # ============================================
    # movie_videos table (1 redundant index)
    # ============================================

    # Duplicate of movie_videos_tmdb_id_index (both are unique indexes on tmdb_id)
    drop_if_exists unique_index(:movie_videos, [:tmdb_id], name: :movie_videos_tmdb_id_constraint)

    # ============================================
    # movie_recommendations table (1 redundant index)
    # ============================================

    # Covered by unique composite index on (source_movie_id, recommended_movie_id, source, type)
    drop_if_exists index(:movie_recommendations, [:source_movie_id],
                     name: :movie_recommendations_source_movie_id_index
                   )

    # ============================================
    # festival_nominations table (4 redundant indexes)
    # ============================================

    # Covered by festival_nominations_ceremony_id_category_id_index
    drop_if_exists index(:festival_nominations, [:ceremony_id],
                     name: :festival_nominations_ceremony_id_index
                   )

    # Covered by festival_nominations_ceremony_id_category_id_movie_id_index
    drop_if_exists index(:festival_nominations, [:ceremony_id, :category_id],
                     name: :festival_nominations_ceremony_id_category_id_index
                   )

    # Covered by festival_nominations_movie_id_won_index and festival_nominations_movie_id_category_id_index
    drop_if_exists index(:festival_nominations, [:movie_id],
                     name: :festival_nominations_movie_id_index
                   )

    # Covered by idx_festival_nominations_movie_scoring (movie_id, won, category_id)
    drop_if_exists index(:festival_nominations, [:movie_id, :won],
                     name: :festival_nominations_movie_id_won_index
                   )

    # ============================================
    # festival_ceremonies table (1 redundant index)
    # ============================================

    # Covered by festival_ceremonies_organization_id_year_index
    drop_if_exists index(:festival_ceremonies, [:organization_id],
                     name: :festival_ceremonies_organization_id_index
                   )

    # ============================================
    # metric_definitions table (1 redundant index)
    # ============================================

    # Covered by metric_definitions_category_subcategory_index
    drop_if_exists index(:metric_definitions, [:category],
                     name: :metric_definitions_category_index
                   )

    # ============================================
    # movies table (1 redundant index)
    # ============================================

    # Covered by movies_title_release_date_index
    drop_if_exists index(:movies, [:title], name: :movies_title_index)
  end

  def down do
    # Recreate all dropped indexes for rollback

    # movie_credits
    create_if_not_exists index(:movie_credits, [:movie_id, :person_id],
                           name: :movie_credits_movie_person_idx
                         )

    create_if_not_exists index(:movie_credits, [:movie_id], name: :movie_credits_movie_id_index)

    create_if_not_exists index(:movie_credits, [:person_id, :job],
                           name: :movie_credits_person_job_idx
                         )

    create_if_not_exists index(:movie_credits, [:person_id, :credit_type],
                           name: :movie_credits_person_type_idx
                         )

    create_if_not_exists index(:movie_credits, [:person_id], name: :movie_credits_person_id_index)

    # external_metrics
    create_if_not_exists index(:external_metrics, [:movie_id],
                           name: :external_metrics_movie_id_index
                         )

    create_if_not_exists index(:external_metrics, [:movie_id, :source, :metric_type],
                           name: :external_metrics_movie_id_source_metric_type_index
                         )

    # movie_videos
    create_if_not_exists unique_index(:movie_videos, [:tmdb_id],
                           name: :movie_videos_tmdb_id_constraint
                         )

    # movie_recommendations
    create_if_not_exists index(:movie_recommendations, [:source_movie_id],
                           name: :movie_recommendations_source_movie_id_index
                         )

    # festival_nominations
    create_if_not_exists index(:festival_nominations, [:ceremony_id],
                           name: :festival_nominations_ceremony_id_index
                         )

    create_if_not_exists index(:festival_nominations, [:ceremony_id, :category_id],
                           name: :festival_nominations_ceremony_id_category_id_index
                         )

    create_if_not_exists index(:festival_nominations, [:movie_id],
                           name: :festival_nominations_movie_id_index
                         )

    create_if_not_exists index(:festival_nominations, [:movie_id, :won],
                           name: :festival_nominations_movie_id_won_index
                         )

    # festival_ceremonies
    create_if_not_exists index(:festival_ceremonies, [:organization_id],
                           name: :festival_ceremonies_organization_id_index
                         )

    # metric_definitions
    create_if_not_exists index(:metric_definitions, [:category],
                           name: :metric_definitions_category_index
                         )

    # movies
    create_if_not_exists index(:movies, [:title], name: :movies_title_index)
  end
end
