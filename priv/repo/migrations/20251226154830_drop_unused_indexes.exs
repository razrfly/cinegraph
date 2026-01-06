defmodule Cinegraph.Repo.Migrations.DropUnusedIndexes do
  @moduledoc """
  Drop unused and redundant indexes per PlanetScale recommendations.

  Addresses issues #34-41:
  - #35: api_lookup_metrics_success_index (unused)
  - #36: idx_movies_1001_by_decade (unused)
  - #37: people_name_lower_pattern_idx (unused)
  - #38: idx_movies_any_canonical (unused)
  - #39: metric_weight_profiles_is_default_index (unused)
  - #41: collaboration_details_year_index (redundant - covered by composite)

  Note: #34 skipped (existing indexes sufficient), #40 already implemented
  """
  use Ecto.Migration

  def up do
    # Phase 2: Redundant index (covered by idx_collaboration_details_year_collab_id)
    drop_if_exists index(:collaboration_details, [:year], name: :collaboration_details_year_index)

    # Phase 3: Unused indexes per PlanetScale recommendations
    drop_if_exists index(:metric_weight_profiles, [:is_default],
                     name: :metric_weight_profiles_is_default_index
                   )

    execute "DROP INDEX IF EXISTS idx_movies_any_canonical"

    execute "DROP INDEX IF EXISTS people_name_lower_pattern_idx"

    execute "DROP INDEX IF EXISTS idx_movies_1001_by_decade"

    drop_if_exists index(:api_lookup_metrics, [:success], name: :api_lookup_metrics_success_index)
  end

  def down do
    # Recreate indexes if rollback needed
    create_if_not_exists index(:collaboration_details, [:year],
                           name: :collaboration_details_year_index
                         )

    create_if_not_exists index(:metric_weight_profiles, [:is_default],
                           name: :metric_weight_profiles_is_default_index
                         )

    create_if_not_exists index(:api_lookup_metrics, [:success],
                           name: :api_lookup_metrics_success_index
                         )

    # These indexes had special definitions - recreate with original logic
    execute """
    CREATE INDEX IF NOT EXISTS idx_movies_any_canonical
    ON movies ((canonical_sources IS NOT NULL AND canonical_sources != '{}'::jsonb))
    """

    execute """
    CREATE INDEX IF NOT EXISTS people_name_lower_pattern_idx
    ON people (lower(name) varchar_pattern_ops)
    """

    execute """
    CREATE INDEX IF NOT EXISTS idx_movies_1001_by_decade
    ON movies (((canonical_sources->>'1001_movies')::int / 10 * 10))
    WHERE canonical_sources ? '1001_movies'
    """
  end
end
