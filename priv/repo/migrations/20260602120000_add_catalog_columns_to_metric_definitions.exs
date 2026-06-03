defmodule Cinegraph.Repo.Migrations.AddCatalogColumnsToMetricDefinitions do
  use Ecto.Migration

  # Issue #1036 Session 1, Layer 0: make metric_definitions the authoritative
  # data-point catalog. Additive columns only; all defaulted/nullable so existing
  # read paths are unaffected.
  def change do
    alter table(:metric_definitions) do
      # 'raw' (straight from a source) | 'derived' (computed transform)
      add :kind, :string, null: false, default: "raw"

      # for derived rows: the transform name (e.g. 'canonical_contribution', 'auteur_track_record')
      add :derivation, :string

      # the lens's internal sub-weighting of this point (0.0 excludes it from :absolute membership)
      add :weight_within_lens, :float, null: false, default: 1.0

      # false = JSONB-trapped / not-yet-extracted; catalogued for honesty, never fed to a live lens
      add :is_available, :boolean, null: false, default: true
    end
  end
end
