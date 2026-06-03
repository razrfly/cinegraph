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

  Ships **5** canon-taste features (four FeatureResolver-backed; `prior_collab_density` (#1044) via
  the per-(person, year) `person_collaboration_trends` matview) PLUS a **missingness-indicator**
  family (#1051 A4): `has_metacritic`, `has_budget`, … each computed from `metric_values_view`
  presence and merged into the same shared assembly. Indicators are gated by catalog
  `is_available` until the keep-criterion (`mix predictions.eval_indicators`) admits them.
  """

  alias Cinegraph.Collaborations
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.{FeatureResolver, FestivalPrestige}

  # Normalization cap: log-scaled counts saturate at this many (≈ the lens's log(1+10) shape).
  @log_cap 10

  # `prior_collab_density` saturates later — it sums distinct lifetime collaborators across a film's
  # whole key-person cast, so it needs a higher cap than the FeatureResolver features' @log_cap.
  # This is the SINGLE source of truth for the threshold: the catalog row's
  # `normalization_params.threshold` reads it via `prior_collab_cap/0` (#1044), so tuning the
  # saturation point is a one-line change here. Adjust this to iterate on the feature's signal.
  @prior_collab_cap 50

  # Chunk movie_ids for the matview query so a full-decade load stays under the pool timeout.
  @chunk 1500
  @timeout :timer.seconds(60)

  # Missingness indicators (#1051 A4): `has_X` = 1.0 when the movie has a non-null value for the
  # underlying objective field, else 0.0. These make field-level *source-absence* an explicit,
  # honestly-vetted feature (canon films are disproportionately the kind mainstream critics never
  # scored), instead of letting the model silently infer canon from a null. Not target-aware, so
  # no leakage concern. Gated by catalog `is_available` until the keep-criterion admits them.
  @indicator_map %{
    "has_imdb_rating" => "imdb_rating",
    "has_metacritic" => "metacritic_metascore",
    "has_rotten_tomatoes" => "rotten_tomatoes_tomatometer",
    "has_budget" => "tmdb_budget",
    "has_revenue" => "tmdb_revenue_worldwide"
  }
  @indicator_codes Map.keys(@indicator_map)

  @supported ~w(canonical_contribution auteur_track_record box_office_roi festival_prestige
                prior_collab_density) ++ @indicator_codes

  @doc "The derived codes this module emits — the routing guard for `DataPointFeatures.load_for/3`."
  def supported_codes, do: @supported

  @doc """
  The log-normalization saturation threshold for `prior_collab_density`. Single source of truth:
  the catalog's `normalization_params.threshold` mirrors this so the two can't drift (#1044).
  """
  def prior_collab_cap, do: @prior_collab_cap

  @doc """
  Load derived feature values for `movies` (which must carry `canonical_sources` and
  `release_date`) under target list `source_key`. Budget/revenue for `box_office_roi` are resolved
  from `external_metrics` via `FeatureResolver` (#1042), so the `tmdb_data` blob is not required.

  Returns `%{movie_id => %{code => value_0..1}}` for the requested `codes` ∩ `supported_codes/0`.
  Every supported code is emitted for every movie (0.0 when the movie has no signal), so coverage
  (fraction nonzero) is meaningful.
  """
  def load(movies, codes, source_key) do
    codes = Enum.filter(codes, &(&1 in @supported))

    if movies == [] or codes == [] do
      %{}
    else
      # Three sources: FeatureResolver bundle (canon/auteur/roi/festival), the person×year matview
      # (prior_collab_density), and metric_values_view presence (the has_* indicators). Resolve each
      # independently, then merge into the shared per-movie vector.
      {indicator_codes, rest} = Enum.split_with(codes, &(&1 in @indicator_codes))
      {pcd_codes, resolver_codes} = Enum.split_with(rest, &(&1 == "prior_collab_density"))

      bundles =
        if resolver_codes == [],
          do: %{},
          else: FeatureResolver.resolve_batch(movies, {:target, source_key})

      densities = if pcd_codes == [], do: %{}, else: load_prior_collab_density(movies)

      indicators =
        if indicator_codes == [],
          do: %{},
          else: load_missingness_indicators(movies, indicator_codes)

      Map.new(movies, fn m ->
        bundle = Map.get(bundles, m.id, %{inputs: %{}, festival_rows: []})
        vals = Map.new(resolver_codes, fn code -> {code, compute(code, bundle)} end)

        vals =
          if pcd_codes == [],
            do: vals,
            else: Map.put(vals, "prior_collab_density", Map.get(densities, m.id, 0.0))

        vals = Map.merge(vals, Map.get(indicators, m.id, %{}))

        {m.id, vals}
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

  # ── prior_collab_density — the matview data path (#1044) ──────────────────────────
  #
  # For each movie, sum its key people's DISTINCT lifetime collaborators gathered strictly BEFORE
  # the film's release year (the leakage guard), then log-normalize. The raw signal is
  # `SUM(new_collaborators)` from the per-(person, year) matview: `new_collaborators` already dedupes
  # against all earlier years, so summing over prior years yields cumulative distinct collaborators
  # with no cross-year double counting. The key-person set (top-20 cast + directors + key crew)
  # mirrors the scope the matview itself is built on. Returns `%{movie_id => value_0..1}` for movies
  # with a positive signal; callers default the rest to 0.0 (no release date / no prior history).
  defp load_prior_collab_density(movies) do
    movies
    |> Enum.map(& &1.id)
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn ids, acc ->
      {:ok, %{rows: rows}} =
        Repo.query(prior_collab_density_sql(), [ids, Collaborations.key_crew_jobs()],
          timeout: @timeout
        )

      Enum.reduce(rows, acc, fn [movie_id, raw], a ->
        Map.put(a, movie_id, log_norm_cap(num(raw), @prior_collab_cap))
      end)
    end)
  end

  # `mc.job = ANY($2)` already covers "Director" (it's in key_crew_jobs); the explicit Director
  # clause is defensive so directors are never dropped if that list changes. `DISTINCT` collapses a
  # person credited under multiple key roles on one film so their collaborators aren't double-summed.
  defp prior_collab_density_sql do
    """
    WITH key_people AS (
      SELECT DISTINCT mc.movie_id, mc.person_id
      FROM movie_credits mc
      WHERE mc.movie_id = ANY($1)
        AND ( (mc.credit_type = 'cast' AND mc.cast_order <= 20)
              OR mc.job = 'Director'
              OR mc.job = ANY($2) )
    )
    SELECT kp.movie_id, SUM(t.new_collaborators)::float AS density
    FROM key_people kp
    JOIN movies m ON m.id = kp.movie_id AND m.release_date IS NOT NULL
    JOIN person_collaboration_trends t ON t.person_id = kp.person_id
    WHERE t.year < EXTRACT(YEAR FROM m.release_date)
    GROUP BY kp.movie_id
    """
  end

  # ── missingness indicators — metric_values_view presence (#1051 A4) ───────────────
  #
  # `has_X` = 1.0 iff the movie has a non-null `normalized_value` for the underlying objective code.
  # Emitted for EVERY movie (1.0 or 0.0), so it's a dense 0/1 feature, not sparse.
  defp load_missingness_indicators(movies, indicator_codes) do
    underlying = indicator_codes |> Enum.map(&@indicator_map[&1]) |> Enum.uniq()
    present = presence_sets(Enum.map(movies, & &1.id), underlying)

    Map.new(movies, fn m ->
      vals =
        Map.new(indicator_codes, fn ind ->
          has? = MapSet.member?(Map.get(present, @indicator_map[ind], MapSet.new()), m.id)
          {ind, if(has?, do: 1.0, else: 0.0)}
        end)

      {m.id, vals}
    end)
  end

  # %{underlying_code => MapSet of movie_ids that have a non-null normalized_value}. Batched.
  defp presence_sets([], _underlying), do: %{}
  defp presence_sets(_ids, []), do: %{}

  defp presence_sets(ids, underlying) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.reduce(%{}, fn chunk, acc ->
      {:ok, %{rows: rows}} =
        Repo.query(
          """
          SELECT metric_code, movie_id
          FROM metric_values_view
          WHERE movie_id = ANY($1) AND metric_code = ANY($2) AND normalized_value IS NOT NULL
          """,
          [chunk, underlying],
          timeout: @timeout
        )

      Enum.reduce(rows, acc, fn [code, id], a ->
        Map.update(a, code, MapSet.new([id]), &MapSet.put(&1, id))
      end)
    end)
  end

  # log(1+x) / log(1+cap), clamped to [0,1] — smooth, saturating, 0 at x=0.
  defp log_norm(x), do: log_norm_cap(x, @log_cap)

  defp log_norm_cap(x, cap) when is_number(x) and x > 0.0,
    do: min(:math.log(1.0 + x) / :math.log(1.0 + cap), 1.0)

  defp log_norm_cap(_, _), do: 0.0

  defp num(n) when is_number(n), do: n / 1
  defp num(_), do: 0.0
end
