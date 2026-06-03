defmodule Cinegraph.Predictions.PooledLinear do
  @moduledoc """
  Pooled (multi-task) linear model class (#1061 Session 2) — the **extensibility proof**: a second
  weight-map class that flows through the whole loop (matrix → ledger → leaderboard) with **zero
  serving rewrite**.

  Trains ONE logistic regression over **all** target lists at once, with the target-list one-hot as
  an additive feature, then **projects** to a per-target weight map. The projected map is the shared
  objective-feature weights; the per-list one-hot weight is an additive bias that shifts every movie
  in a list equally — so it is **rank-invariant within a list** (and absorbed by Platt calibration).
  That is why the projected weight map serves identically through `Cinegraph.Scoring.Bus` with no new
  code, and why a per-list bias need not be represented in the served `Σ wᵢ·featureᵢ` contract.

  Trains on **objective-only** features (`data_point_codes − canon_overlap_codes`), so it structurally
  cannot smuggle canon-overlap circularity. Its `fit_scope/0` is `:pooled`, so `Trainer.run_matrix`
  routes it to the fit-once / project-many path (`fit_pooled/2`) instead of the per-cell `fit/4`.

  Value here is *extensibility proof*, not accuracy — the project already found model class isn't the
  lever (EXGBoost lost). `pooled_linear` is `:experimental` in the lifecycle: it runs and is recorded,
  but is never activated for serving in Session 2.
  """
  @behaviour Cinegraph.Predictions.ModelClass

  alias Cinegraph.Predictions.{Trainer, WeightOptimizer}
  alias Cinegraph.Scoring.DataPointFeatures

  @impl true
  def key, do: "pooled_linear"

  @impl true
  def label, do: "Pooled linear (shared objective weights)"

  @impl true
  def serving_kind, do: :weight_map

  @doc "Training scope (detected by `ModelRegistry.fit_scope/1`): pooled = fit once across all lists."
  def fit_scope, do: :pooled

  # Per-cell fitting is not how a pooled model trains — fail loudly if misrouted (e.g. via fit_weights).
  @impl true
  def fit(_x, _y, _codes, _opts), do: {:error, :pooled_requires_fit_pooled}

  @impl true
  def score(weights, granularity, source_key), do: {granularity, stringify(weights), source_key}

  @impl true
  def serialize(weights), do: stringify(weights)

  @impl true
  def load(map) when is_map(map), do: map

  @impl true
  def explain(weights), do: weights

  @doc """
  Fit one pooled model across `lists` and project to a per-target weight map.

  Returns `{:ok, %{projected: %{source_key => weight_map}, full: weights_with_one_hot, codes:
  objective_codes, lists: lists}}` or `{:error, reason}`. `:projected` is what serving/the matrix
  use; `:full`/`:codes` are exposed for the rank-identity proof test.

  ## Options
    * `:sample_ratio` (default 5) — negative undersampling per list
    * `:alpha` (default 1.0) — L2 strength
    * `:seed` (default 1337) — deterministic undersampling
  """
  def fit_pooled(lists, opts \\ []) do
    ratio = Keyword.get(opts, :sample_ratio, 5)
    alpha = Keyword.get(opts, :alpha, 1.0)
    seed = Keyword.get(opts, :seed, 1337)
    :rand.seed(:exsss, {seed, seed, seed})

    codes = pooled_codes(lists)
    onehot = Enum.map(lists, &("__list:" <> &1))
    columns = codes ++ onehot
    n = length(lists)

    rows =
      lists
      |> Enum.with_index()
      |> Enum.flat_map(fn {sk, i} ->
        labeled = Trainer.labeled_structs_for(sk, ratio)
        structs = Enum.map(labeled, &elem(&1, 0))
        feats = DataPointFeatures.load_for(structs, codes, sk)
        oh = onehot_vec(i, n)

        Enum.map(labeled, fn {m, label} ->
          obj = Enum.map(codes, fn c -> get_in(feats, [m.id, c]) || 0.0 end)
          {obj ++ oh, label}
        end)
      end)

    cond do
      codes == [] ->
        {:error, :no_pooled_features}

      not Enum.any?(rows, fn {_x, y} -> y == 1 end) ->
        {:error, :no_pooled_positives}

      true ->
        x = Enum.map(rows, &elem(&1, 0))
        y = Enum.map(rows, &elem(&1, 1))

        # `:signed` (not simplex): simplex clamps/normalizes the whole vector incl. the one-hot
        # block, which would distort the shared feature weights. Signed preserves relative magnitude;
        # recall@K is rank-invariant and Platt absorbs the scale.
        full =
          WeightOptimizer.fit_raw(x, y, alpha: alpha)
          |> WeightOptimizer.extract_weights(columns, normalize: :signed)

        # Project: keep objective columns only. Dropping the `__list:*` one-hot block leaves a
        # shared objective weight map — identical for every list, differing only by the (dropped)
        # per-list bias, which is rank-irrelevant within a list.
        projected = Map.take(full, codes)

        {:ok,
         %{projected: Map.new(lists, &{&1, projected}), full: full, codes: codes, lists: lists}}
    end
  end

  # Union of each list's objective-only codes (objective surface is list-independent except the
  # target's own / other lists' membership, all of which are canon-overlap and thus excluded).
  defp pooled_codes(lists) do
    lists
    |> Enum.flat_map(fn sk -> Trainer.data_point_codes(sk) -- Trainer.canon_overlap_codes(sk) end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp onehot_vec(i, n), do: for(j <- 0..(n - 1), do: if(j == i, do: 1.0, else: 0.0))

  defp stringify(weights), do: Map.new(weights, fn {k, v} -> {to_string(k), v} end)
end
