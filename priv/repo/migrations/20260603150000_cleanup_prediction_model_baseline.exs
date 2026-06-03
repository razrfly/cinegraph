defmodule Cinegraph.Repo.Migrations.CleanupPredictionModelBaseline do
  use Ecto.Migration

  # #1051 Stage 0 — make the prediction baseline trustworthy before measuring against it.
  # Idempotent; a no-op on fresh databases (test/CI/prod), the cleanup fires only where the
  # offending dev-data rows exist.
  def up do
    # (a) Deactivate national_film_registry — its sole model is graded :insufficient
    #     (recall 0, 5 holdout positives) and the new activation guard refuses such models;
    #     null the existing pointer to match. The model row is kept as an honest record.
    execute("""
    UPDATE movie_lists
    SET active_prediction_model_id = NULL
    WHERE source_key = 'national_film_registry'
    """)

    # (b) Delete inactive models that a NEWER model for the same list has superseded
    #     (e.g. the orphaned earlier 1001_movies model replaced by a later one). This keeps
    #     active models and one-of-a-kind models (incl. the kept NFR record) untouched.
    execute("""
    DELETE FROM prediction_models pm
    WHERE NOT EXISTS (
            SELECT 1 FROM movie_lists ml WHERE ml.active_prediction_model_id = pm.id
          )
      AND EXISTS (
            SELECT 1 FROM prediction_models newer
            WHERE newer.source_key = pm.source_key AND newer.id > pm.id
          )
    """)
  end

  # Data cleanup is not reversible; rollback is a no-op.
  def down, do: :ok
end
