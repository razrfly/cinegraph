defmodule Cinegraph.Predictions.Reliability do
  @moduledoc """
  The per-list **reliability score** (#1039) — one honest, conservative, gamed-proof trust grade
  for a prediction model, derived purely from its out-of-sample `integrity_report`, its
  `calibration`, and the list's `ListFrontier`.

  This is the dashboard warning light, not the engine: it does NOT improve predictions, it says
  *how much you should trust a list's predictions*. It is **structurally incapable of overstating
  accuracy**:

    * **Conservative by construction** — the headline is the **Wilson 95% lower bound** of
      recall@K, never the hopeful point estimate. 8/22 ≈ 36% point → ~21% headline.
    * **Honest abstention** — too few positives, or no lift over the dumb popularity baseline,
      yields `:insufficient` with no headline number at all.
    * **Skill, not score** — graded relative to the popularity baseline (zero-baseline-safe: uses
      absolute margin, since a degenerate holdout can make the baseline literally 0.0).
    * **Caps, never inflation** — a model starts at the grade its lower bound earns, then every
      independent failure (identity calibration, stale frontier, stale model, failed
      pre-registration) can only *lower* it. The final grade is the lowest surviving level, and
      every applied cap records its reason.

  Pure and compute-on-read — NOT persisted: the grade depends on `ListFrontier.fresh?`, which is
  time-dependent, so a stored snapshot would silently go stale. The 3-arg `score/3` core takes
  plain maps (no Repo, no clock) and is what tests exercise; the `%Model{}` wrapper is the only
  arity that touches the DB and the calendar.
  """

  alias Cinegraph.Predictions.{ListFrontier, Model, PreRegistration}
  alias Cinegraph.Repo

  # Below this many holdout positives the recall@K CI is too wide to state a headline at all.
  # Deliberately distinct from (and ≥) ProbabilityCalibration's `@min_positives = 8`, which
  # governs whether a per-film probability *curve* can be fit; this governs whether a headline
  # *accuracy* can be stated.
  @min_positives_for_headline 10

  # Lift gate: recall@K must beat the popularity baseline by this absolute margin. When the
  # baseline is > 0 it must also beat it by this ratio. Both live lists have a 0.0 baseline, so
  # in practice the gate reduces to the margin.
  @min_margin 0.05
  @min_ratio 1.5

  # 95% two-sided normal quantile.
  @z 1.96

  # Grade bands applied to the Wilson LOWER bound (conservative — bands gate the lower bound,
  # not the point estimate). LOCKED 2026-06-03: 1001_movies (lower ≈ 21%) reads LOW.
  @high_band 0.50
  @moderate_band 0.30

  # Grade severity rank — higher is better. `cap/2` is min-by-rank.
  @ranks %{insufficient: 0, low: 1, moderate: 2, high: 3}

  @doc """
  Score a persisted model. Resolves the list frontier (DB + clock) and the pre-registration,
  then delegates to the pure core. This is the only arity that hits the Repo or the calendar.
  """
  def score(%Model{} = model) do
    frontier = ListFrontier.resolve(model.source_key)
    prereg = Repo.preload(model, :pre_registration).pre_registration

    score(model.integrity_report, model.calibration, %{
      is_stale: model.is_stale,
      frontier: frontier,
      threshold: prereg && PreRegistration.threshold_value(prereg),
      prereg?: not is_nil(prereg)
    })
  end

  @doc """
  Pure reliability core. No DB, no clock — everything time- or DB-dependent arrives in `ctx`.

  ## Args
    * `integrity_report` — the model's stored out-of-sample report (recall@K, n_positives,
      n_evaluated, baselines).
    * `calibration` — the model's calibration map (`%{"method" => "platt"|"identity", ...}`) or nil.
    * `ctx` — `%{is_stale:, frontier:, threshold:, prereg?:}` where `frontier` is an already
      resolved `ListFrontier.resolve/1` map.

  Returns the scorecard map (see moduledoc / `score/1`).
  """
  def score(integrity_report, calibration, ctx) when is_map(integrity_report) do
    ir = integrity_report
    full_recall = num(ir["recall_at_k"])
    objective = num(ir["objective_recall_at_k"])
    # The honesty rule (#1051): a grade may only rise via independent (objective) signal, never
    # canon-overlap circularity. When the objective measurement exists, grade on it; older models
    # without it fall back to the full recall (preserves prior behavior).
    recall = objective || full_recall
    n_pos = int(ir["n_positives"])
    pop = num(get_in(ir, ["baselines", "popularity"]))

    {lower, upper} = wilson_bounds(recall, n_pos)
    lift = lift(recall, pop)
    cal_method = calibration_method(calibration)
    frontier = ctx[:frontier] || %{}

    start = band_grade(lower)

    {grade, reasons} =
      Enum.reduce(caps(n_pos, lift, cal_method, frontier, ctx), {start, []}, fn
        {true, cap_to, reason}, {g, rs} -> {cap(g, cap_to), [reason | rs]}
        {false, _cap_to, _reason}, acc -> acc
      end)

    circularity = circularity(full_recall, objective)
    reasons = Enum.reverse(reasons)
    # APPEND the circularity note (CodeRabbit #1062): it's an explanatory aside, not a cap reason.
    # `Mix.Tasks.Predictions.Reliability.top_reason/1` reports `reasons` head as the "capped from"
    # cause — prepending would mask the real cap (stale frontier / calibration / prereg).
    reasons = if r = circularity_reason(circularity), do: reasons ++ [r], else: reasons

    %{
      grade: grade,
      # The grade the accuracy lower bound earns BEFORE caps. When it outranks `grade`, the model
      # was penalized down (e.g. strong recall but stale frontier) — surface "capped from <band>"
      # so a LOW next to a high headline doesn't read as a contradiction.
      band_grade: start,
      headline_pct: headline(grade, lower),
      ci: {round_pct(lower), round_pct(upper)},
      lift: lift,
      # `headline_pct`/`lift` are the GRADED (objective when available) numbers. `full_recall` is
      # the canon-inclusive recall the served model actually achieves; `circularity` is the fraction
      # of that recall attributable to canon-overlap (full − objective) / full.
      full_recall: full_recall,
      objective_recall: objective,
      circularity: circularity,
      power: %{n_positives: n_pos, n_evaluated: int(ir["n_evaluated"])},
      calibration: cal_method,
      freshness: %{
        fresh?: Map.get(frontier, :fresh?, false),
        cutoff_source: Map.get(frontier, :cutoff_source, :none),
        warnings: Map.get(frontier, :warnings, [])
      },
      sufficient?: grade != :insufficient,
      reasons: reasons
    }
  end

  def score(_integrity_report, calibration, ctx),
    do: score(%{}, calibration, ctx)

  # Fraction of full recall that comes from canon-overlap (vs independent signal). nil when there's
  # no objective measurement or no full recall to attribute.
  defp circularity(full, objective)
       when is_number(full) and is_number(objective) and full > 0.0 and full > objective,
       do: Float.round((full - objective) / full, 4)

  defp circularity(_full, _objective), do: nil

  defp circularity_reason(nil), do: nil

  defp circularity_reason(c) when c >= 0.25,
    do:
      "graded on objective signal — #{round(c * 100)}% of full recall is canon-overlap circularity"

  defp circularity_reason(_c), do: nil

  # ── caps ───────────────────────────────────────────────────────────────────────
  # Each tuple: {fires?, grade_ceiling_if_it_fires, reason}. The final grade is the lowest
  # (min-by-rank) of the band-derived start grade and every firing cap.
  defp caps(n_pos, lift, cal_method, frontier, ctx) do
    warnings = Map.get(frontier, :warnings, [])

    [
      {n_pos < @min_positives_for_headline, :insufficient,
       "only #{n_pos} holdout positives (< #{@min_positives_for_headline}) — too few to state an accuracy"},
      {not lift.passes?, :insufficient, lift_reason(lift)},
      {cal_method == "identity", :low,
       "calibration is identity (curve couldn't fit) — per-film probabilities are not trustworthy"},
      {not Map.get(frontier, :fresh?, false) or Map.get(frontier, :cutoff_source, :none) == :none,
       :low,
       "frontier is stale or has no usable cutoff — predictions may be gated on outdated data"},
      {disagreement?(warnings), :moderate,
       "edition year disagrees with newest member — possible stale import or data issue"},
      {ctx[:is_stale] == true, :low, "model is flagged stale vs the current lens configuration"},
      {not ctx[:prereg?] or not clears_threshold?(ctx[:threshold], lift.recall), :low,
       prereg_reason(ctx)}
    ]
  end

  # ── lift (zero-baseline-safe) ────────────────────────────────────────────────────
  defp lift(recall, pop) when is_number(recall) and is_number(pop) do
    margin = recall - pop
    ratio = if pop > 0.0, do: recall / pop, else: nil
    passes = margin >= @min_margin and (is_nil(ratio) or ratio >= @min_ratio)

    %{
      margin: Float.round(margin, 4),
      ratio: ratio && Float.round(ratio, 2),
      passes?: passes,
      recall: recall
    }
  end

  defp lift(_recall, _pop), do: %{margin: nil, ratio: nil, passes?: false, recall: nil}

  defp lift_reason(%{recall: nil}),
    do: "no recall@K measured (zero positives in holdout) — no skill to report"

  # Report whichever condition actually failed (margin vs ratio), not a blanket margin message —
  # a model can clear the absolute margin yet barely beat a large popularity baseline by ratio.
  defp lift_reason(%{margin: m, ratio: r}) do
    cond do
      is_number(m) and m < @min_margin ->
        "does not beat the popularity baseline by the required margin (#{m} < #{@min_margin})"

      is_number(r) and r < @min_ratio ->
        "barely beats popularity — lift ratio #{r}× is below the required #{@min_ratio}×"

      true ->
        "fails the lift gate over the popularity baseline"
    end
  end

  # ── threshold cap (verdict is NOT persisted — recompute, mirroring Trainer.verdict/2) ──
  defp clears_threshold?(nil, _recall), do: true

  defp clears_threshold?(threshold, recall) when is_number(threshold) and is_number(recall),
    do: recall >= threshold

  defp clears_threshold?(_threshold, _recall), do: false

  defp prereg_reason(%{prereg?: false}),
    do: "no pre-registration on record — the hypothesis was not fixed before measuring"

  defp prereg_reason(_),
    do: "out-of-sample recall@K is below the pre-registered failure threshold"

  # ── Wilson 95% interval ──────────────────────────────────────────────────────────
  # k = round(recall * n) successes in n trials. Closed form; no NaN at p̂ ∈ {0, 1}.
  defp wilson_bounds(recall, n) when is_number(recall) and is_integer(n) and n > 0 do
    p = recall
    z2 = @z * @z
    denom = 1 + z2 / n
    center = p + z2 / (2 * n)
    spread = @z * :math.sqrt((p * (1 - p) + z2 / (4 * n)) / n)
    lower = max((center - spread) / denom, 0.0)
    upper = min((center + spread) / denom, 1.0)
    {lower, upper}
  end

  defp wilson_bounds(_recall, _n), do: {nil, nil}

  # ── grade helpers ──────────────────────────────────────────────────────────────
  defp band_grade(nil), do: :insufficient
  defp band_grade(lower) when lower >= @high_band, do: :high
  defp band_grade(lower) when lower >= @moderate_band, do: :moderate
  defp band_grade(_lower), do: :low

  defp cap(a, b), do: if(@ranks[a] <= @ranks[b], do: a, else: b)

  defp headline(:insufficient, _lower), do: "—"
  defp headline(_grade, nil), do: "—"
  defp headline(_grade, lower), do: round_pct(lower)

  defp disagreement?(warnings) when is_list(warnings),
    do: Enum.any?(warnings, &String.contains?(&1, "disagrees"))

  defp disagreement?(_), do: false

  defp calibration_method(%{"method" => m}) when is_binary(m), do: m
  defp calibration_method(_), do: nil

  # ── coercion ─────────────────────────────────────────────────────────────────────
  defp num(v) when is_number(v), do: v / 1
  defp num(_), do: nil

  defp int(v) when is_integer(v), do: v
  defp int(v) when is_float(v), do: trunc(v)
  defp int(_), do: 0

  defp round_pct(nil), do: nil
  defp round_pct(v) when is_number(v), do: Float.round(v * 100, 1)
end
