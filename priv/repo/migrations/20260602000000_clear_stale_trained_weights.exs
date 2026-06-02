defmodule Cinegraph.Repo.Migrations.ClearStaleTrainedWeights do
  use Ecto.Migration

  @moduledoc """
  Issue #1030 — prediction scoring was merged onto the unified 6-lens vocabulary
  (mob, critics, festival_recognition, time_machine, auteurs, box_office).

  Previously-trained weights in `movie_lists.trained_weights` were learned over the
  old 5-criterion vocabulary (… cultural_impact, auteur_recognition) and reference
  dead keys. Null them so they are no longer read; `WeightOptimizer.train(_, save: true)`
  repopulates them over the new lenses.
  """

  def up do
    execute("UPDATE movie_lists SET trained_weights = NULL WHERE trained_weights IS NOT NULL")

    # Cached predictions were computed with the old 5-criterion breakdown
    # (cultural_impact, auteur_recognition). Drop them so the prediction workers
    # repopulate with the six-lens shape; otherwise stale rows would render after deploy.
    execute("DELETE FROM prediction_cache")
  end

  def down do
    # One-way: stale 5-key weights / 5-criterion cached predictions are not
    # recoverable and should not be restored.
    :ok
  end
end
