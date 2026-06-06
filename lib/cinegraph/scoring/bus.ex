defmodule Cinegraph.Scoring.Bus do
  @moduledoc """
  The Layer-2 weighting bus (#1036 Session 3) — one scorer, one `Σ wᵢ·featureᵢ` contract.

  Everything that assigns a score resolves to a weight vector over features, dispatched by
  `feature_set.granularity`:

    * `:lens` — features are the 6 lens scores (0–100). Human presets (`metric_weight_profiles`,
      lens-level) and ML lens-granularity models flow here; this reuses `LensScoring` so it is
      byte-identical to the existing prediction path.
    * `:data_point` — features are per-`metric_code` normalized values (0–1) assembled by
      `DataPointFeatures.load_for/3`: raw codes from `metric_values_view`, plus target-aware
      derived codes from `DerivedFeatures` (#1040). ML data-point models flow here.

  Both produce a 0–100 score (data-point sums, being over 0–1 features with weights summing to
  ~1, are scaled ×100 to match the lens scale). The bus is the FIRST real reader of
  `prediction_models.weights` — it scores from the persisted artifact, not the `trained_weights`
  read-cache.

  The 4 custom lenses (festival/time_machine/auteurs/box_office) are NOT linear in the raw
  metric_codes; the `:lens` path keeps them as opaque features. The bus does not attempt to
  linearize them — that boundary is intentional and documented in #1036.
  """

  import Ecto.Query

  alias Cinegraph.Predictions.{LensScoring, Model}
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.DataPointFeatures

  @doc """
  Score movies with a model or an explicit spec. Returns `%{movie_id => score_0_100}`.

  Accepts:
    * `%Model{}` — granularity + weights read from the artifact
    * `{:lens, weights_atom_or_string, source_key}`
    * `{:data_point, %{code => weight}, source_key}`
  """
  def score(movies, model_or_spec, opts \\ [])

  def score(movies, %Model{feature_set: fs, weights: weights, source_key: source_key}, opts) do
    case granularity(fs) do
      "data_point" -> score(movies, {:data_point, weights, source_key}, opts)
      _ -> score(movies, {:lens, weights, source_key}, opts)
    end
  end

  def score(movies, {:lens, weights, source_key}, _opts) do
    LensScoring.batch_score_movies(movies, atomize_lens_weights(weights), source_key)
    |> Map.new(fn %{movie: m, prediction: p} -> {m.id, p.total_score} end)
  end

  def score(movies, {:data_point, weights, source_key}, _opts) do
    codes = Map.keys(weights)
    feats = DataPointFeatures.load_for(movies, codes, source_key)

    Map.new(movies, fn movie ->
      vec = Map.get(feats, movie.id, %{})

      sum =
        Enum.reduce(weights, 0.0, fn {code, w}, acc -> acc + w * (vec[code] || 0.0) end)

      {movie.id, Float.round(min(max(sum * 100.0, 0.0), 100.0), 1)}
    end)
  end

  @doc """
  Exact per-film contribution breakdown for a **data-point** weight-map model (#1076 P1) —
  `contribution = weight × feature × 100` per code, mirroring `score/3` term-for-term (same
  `DataPointFeatures.load_for/3` assembly), so the terms sum to the film's score (pre-clamp).
  The model is linear; this is the truth, not an approximation.

  Returns `%{movie_id => [%{code, value, weight, contribution}]}` — only nonzero terms,
  signed, sorted by |contribution| desc. Lens-granularity models return
  `{:error, :unsupported_granularity}` (the 4 custom lenses are opaque at this layer — see
  moduledoc).
  """
  def contributions(movies, model_or_spec)

  def contributions(movies, %Model{feature_set: fs, weights: weights, source_key: source_key}) do
    case granularity(fs) do
      "data_point" -> contributions(movies, {:data_point, weights, source_key})
      _ -> {:error, :unsupported_granularity}
    end
  end

  def contributions(movies, {:data_point, weights, source_key}) do
    codes = Map.keys(weights)
    feats = DataPointFeatures.load_for(movies, codes, source_key)

    Map.new(movies, fn movie ->
      vec = Map.get(feats, movie.id, %{})

      terms =
        weights
        |> Enum.flat_map(fn {code, w} ->
          v = vec[code] || 0.0
          c = w * v * 100.0

          if c == 0.0,
            do: [],
            else: [%{code: code, value: v, weight: w, contribution: Float.round(c, 2)}]
        end)
        |> Enum.sort_by(&abs(&1.contribution), :desc)

      {movie.id, terms}
    end)
  end

  def contributions(_movies, _spec), do: {:error, :unsupported_granularity}

  @doc "Load the active model artifact for a list, or nil. The bus's model source."
  def active_model(source_key) when is_binary(source_key) do
    Repo.one(
      from m in Model,
        join: l in "movie_lists",
        on: l.active_prediction_model_id == m.id,
        where: l.source_key == ^source_key,
        limit: 1
    )
  end

  @lens_atoms LensScoring.scoring_criteria()
  @lens_by_string Map.new(@lens_atoms, &{Atom.to_string(&1), &1})

  # Lens weights may arrive as atom or string keys (artifact JSONB stores strings). Keys are
  # whitelisted to the known lens vocabulary — an unknown/stale key (e.g. from old persisted
  # weights or a renamed lens) is skipped rather than crashing the whole scoring request.
  defp atomize_lens_weights(weights) do
    Enum.reduce(weights, %{}, fn {k, v}, acc ->
      case lens_atom(k) do
        nil -> acc
        atom -> Map.put(acc, atom, v)
      end
    end)
  end

  defp lens_atom(k) when is_atom(k), do: if(k in @lens_atoms, do: k)
  defp lens_atom(k) when is_binary(k), do: Map.get(@lens_by_string, k)

  defp granularity(%{"granularity" => g}), do: g
  defp granularity(%{granularity: g}), do: g
  defp granularity(_), do: "lens"
end
