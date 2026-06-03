defmodule Cinegraph.Repo.Migrations.EnforcePredictionModelPrereg do
  use Ecto.Migration

  # #1036 closeout — Integrity Protocol Rule 1 at the DB level: every prediction_models row
  # MUST be linked to a pre-registration. Removes the legacy non-protocol artifacts (saved by
  # the now-retired WeightOptimizer save path) and hard-enforces NOT NULL so no path can write
  # an un-pre-registered model again.
  def up do
    # Detach any list pointing at a to-be-removed model, then drop the orphans.
    execute("""
    UPDATE movie_lists SET active_prediction_model_id = NULL
    WHERE active_prediction_model_id IN (SELECT id FROM prediction_models WHERE prereg_id IS NULL)
    """)

    execute("DELETE FROM prediction_models WHERE prereg_id IS NULL")

    # Only flip nullability — the FK already exists, so don't re-declare references/2.
    execute("ALTER TABLE prediction_models ALTER COLUMN prereg_id SET NOT NULL")
  end

  def down do
    execute("ALTER TABLE prediction_models ALTER COLUMN prereg_id DROP NOT NULL")
  end
end
