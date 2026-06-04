defmodule Cinegraph.Predictions.MatrixPlanner do
  @moduledoc """
  The matrix planner (#1065 Session 1, Phase 2) — the single source of truth for *which cells a
  matrix run executes*, so `mix predictions.matrix --plan` can print the exact grid + a
  pool-weighted ETA **without executing**.

  `Trainer.run_matrix/1` resolves its defaults and per-cell/pooled split through `resolve/1` here,
  and `plan/1` enumerates that same grid — so the planned count can't drift from a real run. Cells
  fan out per training scope, not as one flat product:

    * **per-cell** classes (e.g. `linear_logreg`): `lists × strategies × buckets × weight_variants`.
    * **pooled** classes (e.g. `pooled_linear`): fit once across all lists, then **one eval per
      list** (objective-only / temporal by construction — see `Trainer.run_pooled_classes/5`).

  `estimate/2` predicts wall-clock from the Phase-1 history with a genuinely **pool-weighted** cost
  model: it fits `duration_ms ≈ k · n_evaluated + b` (least squares, with `r²`) over historical
  cells, and prices each planned cell from its *estimated pool size*. A `criterion/static/all` cell
  (a far larger non-member pool) therefore costs far more than an `afi_100` one — not
  `remaining × flat_avg`. A seen shape uses its empirical median duration directly; an unseen shape
  uses the fitted model (when trustworthy); shapes with no basis at all are flagged, never zeroed.
  """
  import Ecto.Query

  alias Cinegraph.Movies.MovieLists
  alias Cinegraph.Predictions.{ExperimentLedger, ModelRegistry}
  alias Cinegraph.Repo

  @default_concurrency 4
  @heaviest_n 5
  # Use the fitted `duration ≈ k · n_evaluated` model to extrapolate to UNSEEN shapes only when it's
  # trustworthy; otherwise fall back to the empirical per-shape median. Reported either way.
  @min_r2 0.5

  @doc """
  Resolve the matrix run defaults and the per-cell/pooled class split from `opts`.

  Mirrors `Trainer.run_matrix/1` exactly (it calls this); kept here so the planner and the runner
  share one definition of the grid.
  """
  def resolve(opts) do
    lists = Keyword.get(opts, :lists) || MovieLists.get_active_source_keys()
    classes = Keyword.get(opts, :classes) || ModelRegistry.keys()
    strategies = Keyword.get(opts, :strategies) || ~w(temporal static)
    buckets = Keyword.get(opts, :buckets) || [:objective_only, :canon_overlap, :all]
    variants = Keyword.get(opts, :weight_variants) || [[]]

    {pooled, per_cell} = Enum.split_with(classes, &(ModelRegistry.fit_scope(&1) == :pooled))

    %{
      lists: lists,
      per_cell_classes: per_cell,
      pooled_classes: pooled,
      strategies: strategies,
      buckets: buckets,
      variants: variants
    }
  end

  @doc """
  The planner-generated cell grid for `opts` — the exact cells a real run would execute.

  Returns `%{total:, cells:, per_cell:, pooled:, by_class:}` where each cell is a descriptor map
  `%{source_key:, model_class:, strategy:, feature_bucket:, weight_variant:, kind:}`.
  """
  def plan(opts) do
    r = resolve(opts)

    per_cell =
      for sk <- r.lists,
          class <- r.per_cell_classes,
          strat <- r.strategies,
          bucket <- r.buckets,
          v <- r.variants do
        %{
          source_key: sk,
          model_class: class,
          strategy: strat,
          feature_bucket: bucket,
          weight_variant: v,
          kind: :per_cell
        }
      end

    # Pooled fits once across all lists, then evaluates each list objective-only/temporal.
    pooled =
      for class <- r.pooled_classes, sk <- r.lists do
        %{
          source_key: sk,
          model_class: class,
          strategy: "temporal",
          feature_bucket: :objective_only,
          weight_variant: [],
          kind: :pooled
        }
      end

    cells = per_cell ++ pooled

    %{
      total: length(cells),
      cells: cells,
      per_cell: per_cell,
      pooled: pooled,
      by_class: by_class(cells)
    }
  end

  @doc """
  Attach a pool-weighted ETA to a `plan/1` result from historical `duration_ms`/`n_evaluated`.

  `opts` accepts `:max_concurrency` (default #{@default_concurrency}). Returns
  `%{total:, concurrency:, eta_ms:, basis_count:, cost_model:, by_class:, heaviest:, no_history:}`:

    * `eta_ms` — `ceil(Σ predicted(cell) / concurrency)`, summed over cells that *have* a basis.
    * `basis_count` — number of historical cells the estimate is built from.
    * `cost_model` — `%{k, b, r2, n}` for `duration_ms ≈ k · n_evaluated + b` (or `nil` if it can't
      be fit), so the estimate is inspectable: `k` is ms per movie-score.
    * `by_class` — per-class `%{class, kind, count, temporal, static, predicted_ms}`.
    * `heaviest` — the #{@heaviest_n} costliest predicted cells.
    * `no_history` — cells with no basis at all (flagged, not zeroed).

  Per cell: an empirically-seen `(source_key, strategy, bucket)` uses its median duration directly;
  an unseen shape is priced by the fitted model from its estimated pool size (median `n_evaluated`
  for the shape, else global); otherwise `(strategy, bucket)` then global median duration.
  """
  def estimate(%{cells: cells} = plan, opts \\ []) do
    concurrency = max(Keyword.get(opts, :max_concurrency, @default_concurrency), 1)
    history = load_history()
    cost_model = fit_cost_model(history)

    priced = price_cells(cells, history: history)
    {with_history, no_history} = Enum.split_with(priced, &(&1.predicted_ms != nil))

    eta_ms =
      case with_history do
        [] -> 0
        _ -> ceil(Enum.sum(Enum.map(with_history, & &1.predicted_ms)) / concurrency)
      end

    heaviest =
      with_history
      |> Enum.sort_by(& &1.predicted_ms, :desc)
      |> Enum.take(@heaviest_n)

    %{
      total: plan.total,
      concurrency: concurrency,
      eta_ms: eta_ms,
      basis_count: length(history),
      cost_model: cost_model,
      by_class: priced_by_class(priced),
      heaviest: heaviest,
      no_history: no_history
    }
  end

  @doc """
  Attach `:predicted_ms` (and `:pool_estimate`) to each cell descriptor from historical
  `duration_ms`/`n_evaluated`. The single pricing path — `estimate/2` uses it for a full plan, and the
  runs dashboard uses it to price the *remaining* cells of an in-flight run for a live ETA.

  Pass `:history` (a `load_history/0` result) to reuse an already-loaded history; otherwise it loads.
  A cell with no basis at all gets `predicted_ms: nil` (flagged, never zeroed).
  """
  def price_cells(cells, opts \\ []) do
    history = Keyword.get_lazy(opts, :history, &load_history/0)
    cost_model = fit_cost_model(history)
    use_model? = cost_model != nil and cost_model.r2 >= @min_r2 and cost_model.k > 0

    dur_full = group_values(history, &{&1.source_key, &1.strategy, &1.bucket}, & &1.duration_ms)
    dur_shape = group_values(history, &{&1.strategy, &1.bucket}, & &1.duration_ms)
    dur_global = median(Enum.map(history, & &1.duration_ms))

    pool_full = group_values(history, &{&1.source_key, &1.strategy, &1.bucket}, & &1.n_evaluated)
    pool_shape = group_values(history, &{&1.strategy, &1.bucket}, & &1.n_evaluated)
    pool_global = median(for h <- history, is_integer(h.n_evaluated), do: h.n_evaluated)

    Enum.map(cells, fn cell ->
      bucket = to_string(cell.feature_bucket)
      full = {cell.source_key, cell.strategy, bucket}
      shape = {cell.strategy, bucket}

      pool = median_for(pool_full, full) || median_for(pool_shape, shape) || pool_global

      raw =
        cond do
          ds = Map.get(dur_full, full) -> median(ds)
          use_model? and pool -> cost_model.k * pool + cost_model.b
          ds = Map.get(dur_shape, shape) -> median(ds)
          dur_global != nil -> dur_global
          true -> nil
        end

      cell
      |> Map.put(:predicted_ms, raw && max(round(raw), 0))
      |> Map.put(:pool_estimate, pool)
    end)
  end

  @doc """
  The fitted `duration_ms ≈ k · n_evaluated + b` model over all history (`%{k, b, r2, n}` or `nil`) —
  for the dashboard's timing report. `k` is ms per movie-score.
  """
  def cost_model, do: load_history() |> fit_cost_model()

  # ── internals ─────────────────────────────────────────────────────────────────────

  defp by_class(cells) do
    cells
    |> Enum.group_by(& &1.model_class)
    |> Enum.map(fn {class, group} ->
      %{
        class: class,
        kind: hd(group).kind,
        count: length(group),
        temporal: Enum.count(group, &(&1.strategy == "temporal")),
        static: Enum.count(group, &(&1.strategy == "static"))
      }
    end)
    |> Enum.sort_by(& &1.class)
  end

  defp priced_by_class(priced) do
    priced
    |> Enum.group_by(& &1.model_class)
    |> Enum.map(fn {class, group} ->
      predicted = group |> Enum.map(& &1.predicted_ms) |> Enum.reject(&is_nil/1)

      %{
        class: class,
        kind: hd(group).kind,
        count: length(group),
        temporal: Enum.count(group, &(&1.strategy == "temporal")),
        static: Enum.count(group, &(&1.strategy == "static")),
        # nil (not 0) when nothing in the class had history → renders as "—", not a bogus "0s".
        predicted_ms: if(predicted == [], do: nil, else: Enum.sum(predicted))
      }
    end)
    |> Enum.sort_by(& &1.class)
  end

  defp load_history do
    Repo.all(
      from e in ExperimentLedger,
        where: not is_nil(e.duration_ms),
        select: %{
          source_key: e.source_key,
          strategy: e.backtest_strategy,
          bucket: e.feature_bucket,
          duration_ms: e.duration_ms,
          n_evaluated: e.n_evaluated
        }
    )
  end

  # Group history into `key => [values]`, dropping rows whose value is nil (e.g. a `failed` row has
  # no n_evaluated). Keeps the medians honest.
  defp group_values(history, key_fun, val_fun) do
    Enum.reduce(history, %{}, fn h, acc ->
      case val_fun.(h) do
        nil -> acc
        v -> Map.update(acc, key_fun.(h), [v], &[v | &1])
      end
    end)
  end

  defp median_for(map, key) do
    case Map.get(map, key) do
      nil -> nil
      values -> median(values)
    end
  end

  # Least-squares fit of `duration_ms ≈ k · n_evaluated + b` over cells that recorded a pool size,
  # with the coefficient of determination `r²` and a **relative error band** `rel_err` (residual RMSE
  # ÷ mean duration) — the stated ± band an ETA built from this model is expected to land within.
  # Returns nil when there's too little signal (< 2 points, or no variance in pool size).
  defp fit_cost_model(history) do
    pts =
      for h <- history,
          is_integer(h.n_evaluated) and h.n_evaluated > 0,
          do: {h.n_evaluated, h.duration_ms}

    case pts do
      [_, _ | _] ->
        n = length(pts)
        mx = Enum.sum(Enum.map(pts, &elem(&1, 0))) / n
        my = Enum.sum(Enum.map(pts, &elem(&1, 1))) / n

        {sxx, sxy, syy} =
          Enum.reduce(pts, {0.0, 0.0, 0.0}, fn {x, y}, {axx, axy, ayy} ->
            dx = x - mx
            dy = y - my
            {axx + dx * dx, axy + dx * dy, ayy + dy * dy}
          end)

        if sxx == 0.0 do
          nil
        else
          k = sxy / sxx
          b = my - k * mx
          sse = Enum.reduce(pts, 0.0, fn {x, y}, acc -> acc + :math.pow(y - (k * x + b), 2) end)
          rmse = :math.sqrt(sse / n)

          %{
            k: k,
            b: b,
            r2: if(syy == 0.0, do: 1.0, else: sxy * sxy / (sxx * syy)),
            rel_err: if(my == 0.0, do: 0.0, else: rmse / my),
            n: n
          }
        end

      _ ->
        nil
    end
  end

  defp median([]), do: nil

  defp median(durations) do
    sorted = Enum.sort(durations)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end
end
