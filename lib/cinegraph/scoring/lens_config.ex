defmodule Cinegraph.Scoring.LensConfig do
  @moduledoc """
  Stable fingerprints for the lens configuration and a model's weights (#1036 Layer 2).

  `lens_config_hash/0` digests the active lens configuration — the `@lens_version` plus,
  per lens, its active member `metric_code`s and `weight_within_lens` (from the catalog).
  Trained `:lens`-granularity models record this hash so a lens change (membership,
  weight, or version) flips the model `is_stale`.

  `weights_hash/4` digests a model's *meaning*, not just its numbers — granularity,
  ordered features, weights, `model_version`, and `lens_config_hash` — so two models with
  identical numeric weights but a different feature set never collide.

  Hashing reuses the MD5(term_to_binary) + lowercase hex pattern used elsewhere
  (`Cinegraph.Cache.PredictionsCache`).
  """
  alias Cinegraph.Metrics
  alias Cinegraph.Scoring.Lenses

  @doc "Stable fingerprint of the active lens configuration."
  def lens_config_hash do
    members =
      for lens <- Lenses.all_strings() do
        codes =
          lens
          |> Metrics.absolute_lens_members()
          |> Enum.map(&{&1.code, &1.weight_within_lens})

        {lens, codes}
      end

    hash({Lenses.lens_version(), members})
  end

  @doc """
  Stable fingerprint of a model's weight vector + its meaning. `lens_config_hash` should
  be the current lens config for `:lens` granularity, or nil for `:data_point`.
  """
  def weights_hash(feature_set, weights, model_version, lens_config_hash) do
    granularity = fetch(feature_set, "granularity") || fetch(feature_set, :granularity)

    features =
      (fetch(feature_set, "features") || fetch(feature_set, :features) || [])
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    sorted_weights =
      weights
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort()

    hash({granularity, features, sorted_weights, model_version, lens_config_hash})
  end

  defp fetch(map, key), do: Map.get(map, key)

  defp hash(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:md5, &1))
    |> Base.encode16(case: :lower)
  end
end
