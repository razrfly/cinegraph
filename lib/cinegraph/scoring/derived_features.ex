defmodule Cinegraph.Scoring.DerivedFeatures do
  @moduledoc """
  Per-(movie, target) **derived** prediction features for the data-point ML surface (#1040).

  The catalog's `kind: "derived"` features encode *canon taste* — the signal a generic-acclaim
  model is blind to. Two of them are **target-aware** (`canonical_contribution{L}`,
  `auteur_track_record{L}`): their value depends on the list `L` being predicted and must be
  leakage-stripped per target, so they **cannot** live in the static `metric_values_view` (it has
  no `source_key` parameter). Rather than reinvent that logic, this module reuses the lens path's
  already-correct, batched, leakage-stripped `FeatureResolver` and normalizes each feature to
  `[0,1]` (the catalog marks these `custom`, so the view can't auto-normalize them — the scaling
  lives here, deterministically, and is shared by training and serving via
  `DataPointFeatures.load_for/3`).

  Ships **4** features; `prior_collab_density` is deferred (separate person×year matview wiring)
  and catalogued `is_available: false`, so it is intentionally NOT in `supported_codes/0`.
  """

  alias Cinegraph.Scoring.{FeatureResolver, FestivalPrestige}

  # Normalization cap: log-scaled counts saturate at this many (≈ the lens's log(1+10) shape).
  @log_cap 10

  @supported ~w(canonical_contribution auteur_track_record box_office_roi festival_prestige)

  @doc "The derived codes this module emits — the routing guard for `DataPointFeatures.load_for/3`."
  def supported_codes, do: @supported

  @doc """
  Load derived feature values for `movies` (which must carry `canonical_sources`,
  `tmdb_data{budget,revenue}`, `release_date`) under target list `source_key`.

  Returns `%{movie_id => %{code => value_0..1}}` for the requested `codes` ∩ `supported_codes/0`.
  Every supported code is emitted for every movie (0.0 when the movie has no signal), so coverage
  (fraction nonzero) is meaningful.
  """
  def load(movies, codes, source_key) do
    codes = Enum.filter(codes, &(&1 in @supported))

    if movies == [] or codes == [] do
      %{}
    else
      bundles = FeatureResolver.resolve_batch(movies, {:target, source_key})

      Map.new(movies, fn m ->
        bundle = Map.get(bundles, m.id, %{inputs: %{}, festival_rows: []})
        {m.id, Map.new(codes, fn code -> {code, compute(code, bundle)} end)}
      end)
    end
  end

  # ── per-feature computation → [0,1] ──────────────────────────────────────────────

  # OTHER canonical lists the film is on (target already stripped by FeatureResolver).
  defp compute("canonical_contribution", %{inputs: inputs}),
    do: log_norm(num(inputs[:canonical_count]))

  # How many of the film's directors' OTHER films are on the target list (self already excluded).
  defp compute("auteur_track_record", %{inputs: inputs}),
    do: log_norm(num(inputs[:director_target_count]))

  # Revenue / budget, only when both are present and positive.
  defp compute("box_office_roi", %{inputs: inputs}) do
    budget = num(inputs[:tmdb_budget])
    revenue = num(inputs[:tmdb_revenue])
    if budget > 0.0 and revenue > 0.0, do: log_norm(revenue / budget), else: 0.0
  end

  # Tier-weighted festival prestige, same tiers as the lens; rows are
  # `[festival, category, won, year, win_score, nom_score]` (year at index 3 is skipped).
  defp compute("festival_prestige", %{festival_rows: rows}) do
    rows
    |> Enum.map(fn [festival, category, won, _year, win_score, nom_score] ->
      FestivalPrestige.score_nomination(festival, category, won, win_score, nom_score)
    end)
    |> Enum.sum()
    |> Kernel./(100.0)
    |> min(1.0)
  end

  defp compute(_code, _bundle), do: 0.0

  # log(1+x) / log(1+cap), clamped to [0,1] — smooth, saturating, 0 at x=0.
  defp log_norm(x) when is_number(x) and x > 0.0,
    do: min(:math.log(1.0 + x) / :math.log(1.0 + @log_cap), 1.0)

  defp log_norm(_), do: 0.0

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: 0.0
end
