defmodule Cinegraph.Predictions do
  @moduledoc """
  The Predictions context — model lifecycle operations (#1036).

  Currently the home of lens-evolution **staleness propagation**: when a lens changes (its
  `@lens_version`, membership, or a member's `weight_within_lens`/`active` flag), the active
  `lens_config_hash` changes, and any `:lens`-granularity `prediction_models` trained against
  the old configuration must be flagged `is_stale` so they're retrained. `:data_point` models
  are keyed to `metric_code`s, not lenses, so they are deliberately untouched.
  """

  import Ecto.Query

  alias Cinegraph.Predictions.Model
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.LensConfig

  @doc """
  Flag every `:lens`-granularity model whose `lens_config_hash` no longer matches the current
  lens configuration as `is_stale = true`. Idempotent (a model already matching, or already
  stale, is left as-is) and leaves `:data_point` models untouched. Returns the number flipped.

  Call after a lens change / cache re-warm.
  """
  def mark_stale_lens_models do
    current = LensConfig.lens_config_hash()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Model
      |> where([m], fragment("?->>'granularity' = 'lens'", m.feature_set))
      |> where([m], is_nil(m.lens_config_hash) or m.lens_config_hash != ^current)
      |> where([m], m.is_stale == false)
      |> Repo.update_all(set: [is_stale: true, updated_at: now])

    count
  end

  @doc "List currently-stale models (optionally scoped to a list)."
  def stale_models(source_key \\ nil) do
    Model
    |> where([m], m.is_stale == true)
    |> then(fn q -> if source_key, do: where(q, [m], m.source_key == ^source_key), else: q end)
    |> Repo.all()
  end
end
