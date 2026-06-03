defmodule Cinegraph.Scoring.LensFormulas do
  @moduledoc """
  Single source of truth for every scoring lens formula, **mode-aware**.

  There is one definition per lens, but each takes a `mode`:

    * `:absolute` — the discovery view. Plain, target-independent formulas on a
      0–10 scale. Lifted verbatim from the historical `MovieScoring` so that
      `/movies` browse + sort scores never change (guarded by a parity test).
    * `{:target, source_key}` — the prediction view. The accuracy-tuned formulas
      lifted from the historical 5-criterion prediction scorer, on a 0–100 scale. These add
      era-weighted vote counts (`mob`), a log-canonical + ROI decomposition of the
      old `cultural_impact` (into `time_machine` + `box_office`), and a
      list-relative director track-record (`auteurs`). The caller is responsible
      for stripping `source_key` from `canonical_sources` before building inputs,
      so membership in the target list never leaks into the score.

  Both `MovieScoring` (Absolute, feeds `movie_score_caches`) and
  `Cinegraph.Predictions.LensScoring` (Target, drives predictions) compute lenses
  through this module — they can no longer drift apart.

  ## Inputs

  Each function takes an `inputs` map and a `mode`. Callers populate only the keys
  a given lens/mode reads:

    * `:imdb_rating`, `:tmdb_rating` — 0–10 audience ratings
    * `:imdb_votes` — IMDb vote count
    * `:metacritic`, `:rt_tomatometer` — 0–100 critic scores
    * `:popularity` — TMDb popularity_score (Absolute `time_machine`)
    * `:budget`, `:revenue` — external_metrics financials (Absolute `box_office`)
    * `:tmdb_budget`, `:tmdb_revenue` — external_metrics financials (Target `box_office`, #1042)
    * `:canonical_count` — `map_size(canonical_sources)` AFTER target-stripping
    * `:release_year` — for era weighting
    * `:person_quality` — role-weighted top-10 quality, 0–100 (Absolute `auteurs`)
    * `:director_target_count`, `:director_avg_imdb` — director's presence on the
      target list + avg IMDb rating across their filmography (Target `auteurs`)
  """

  alias Cinegraph.Scoring.FestivalPrestige

  # ── mob ────────────────────────────────────────────────────────────────────

  @doc "Audience lens. Absolute: 0–10 avg(imdb, tmdb). Target: era-weighted, 0–100."
  def mob(inputs, :absolute) do
    sources =
      [inputs[:imdb_rating], inputs[:tmdb_rating]]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 > 0))

    if sources == [], do: nil, else: Enum.sum(sources) / length(sources)
  end

  def mob(inputs, {:target, _source_key}) do
    rating_scores =
      [inputs[:imdb_rating], inputs[:tmdb_rating]]
      |> Enum.reject(&is_nil/1)
      # imdb/tmdb rating_average are 0–10 → normalize to 0–100
      |> Enum.map(&(&1 * 10))
      |> Enum.filter(&(&1 > 0))

    imdb_votes = inputs[:imdb_votes] || 0.0
    release_year = inputs[:release_year] || 2000

    if rating_scores == [] do
      nil
    else
      avg_rating = Enum.sum(rating_scores) / length(rating_scores)
      rating_component = avg_rating * 0.70
      scaled_votes = imdb_votes * vote_scale_for_year(release_year)
      # log(1 + 100_000) ≈ 11.51 → 30 pts at 100K scaled votes
      vote_component = min(:math.log(1 + scaled_votes) / :math.log(1 + 100_000) * 30.0, 30.0)
      min(rating_component + vote_component, 100.0)
    end
  end

  # ── critics ──────────────────────────────────────────────────────────────

  @doc "Critics lens. Absolute: 0–10. Target: 0–100. avg(metacritic, rt_tomatometer)."
  def critics(inputs, :absolute) do
    sources =
      [inputs[:rt_tomatometer], inputs[:metacritic]]
      |> Enum.reject(fn v -> is_nil(v) or v == 0 end)
      |> Enum.map(fn v -> v / 100.0 * 10.0 end)

    if sources == [], do: nil, else: Enum.sum(sources) / length(sources)
  end

  def critics(inputs, {:target, _source_key}) do
    scores =
      [inputs[:metacritic], inputs[:rt_tomatometer]]
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&(&1 > 0))

    if scores == [], do: nil, else: min(Enum.sum(scores) / length(scores), 100.0)
  end

  # ── generic :weighted_mean (catalog-driven; #1036 Layer 1) ─────────────────

  @doc """
  Generic `:weighted_mean` lens (0–10): the `weight_within_lens`-weighted mean of its
  catalog members, each normalized to 0–10 via `value / scale_max * 10`.

  Members are `%{value: number | nil, scale_max: number, weight: number}` built from
  `metric_definitions` (so adding a member to the catalog flows in here with no code
  change). A member counts only when present (`value` non-nil and `> 0`). Returns nil
  when no member is present — matching the prior bespoke mob/critics behaviour.
  """
  def weighted_mean(members) do
    present =
      Enum.filter(members, fn m ->
        is_number(m.value) and m.value > 0 and is_number(m.scale_max) and m.scale_max > 0 and
          is_number(m.weight) and m.weight > 0
      end)

    case present do
      [] ->
        nil

      _ ->
        {weighted_sum, weight_total} =
          Enum.reduce(present, {0.0, 0.0}, fn m, {ws, wt} ->
            # Normalize each member to the 0–10 lens scale via its catalog raw_scale_max.
            {ws + m.value / m.scale_max * 10.0 * m.weight, wt + m.weight}
          end)

        weighted_sum / weight_total
    end
  end

  # ── festival_recognition ─────────────────────────────────────────────────

  @doc """
  Festival lens. Both modes use `FestivalPrestige`, differing only in ceiling/scale.

  Absolute rows: `[abbrev, category, won, win_score, nom_score]` (ceiling 10.0).
  Target rows:   `[festival, category, won, year, win_score, nom_score]` (ceiling 100.0,
  per-nomination capped then summed — matching the historical predictions path).
  """
  def festival(nomination_rows, :absolute) do
    FestivalPrestige.score_nominations(nomination_rows, 10.0)
  end

  def festival([], {:target, _source_key}), do: 0.0

  def festival(nomination_rows, {:target, _source_key}) do
    nomination_rows
    |> Enum.map(fn [festival, category, won, _year, win_score, nom_score] ->
      min(FestivalPrestige.score_nomination(festival, category, won, win_score, nom_score), 100.0)
    end)
    |> Enum.sum()
    |> min(100.0)
  end

  # ── time_machine ───────────────────────────────────────────────────────────

  @doc """
  Cultural-memory lens. Absolute: canonical presence + TMDb popularity (0–10).
  Target: log-canonical (0–70) + era-aware IMDb critical mass (0–25) — the
  canonical/popularity portion of the old `cultural_impact`. `:canonical_count`
  must already exclude the target list (stripped by the caller).
  """
  def time_machine(inputs, :absolute) do
    canonical_count = inputs[:canonical_count] || 0
    popularity = inputs[:popularity] || 0

    popularity_score =
      if popularity > 0, do: :math.log(popularity + 1) / :math.log(1000), else: 0

    min(10.0, canonical_count * 2.0 + popularity_score * 5.0)
  end

  def time_machine(inputs, {:target, _source_key}) do
    canonical_count = inputs[:canonical_count] || 0
    canonical_score = min(:math.log(1 + canonical_count) / :math.log(1 + 10) * 70.0, 70.0)

    popularity_score =
      imdb_popularity_score(
        inputs[:imdb_rating] || 0.0,
        inputs[:imdb_votes] || 0,
        inputs[:release_year] || 2000
      )

    min(canonical_score + popularity_score, 100.0)
  end

  # ── box_office ─────────────────────────────────────────────────────────────

  @doc """
  Financial lens. Absolute: log revenue (60%) + log ROI (40%) from external_metrics
  (0–10). Target: ROI bands from external-metrics budget/revenue (0–25) — the ROI
  portion of the old `cultural_impact` (#1042: was the raw `tmdb_data` blob).
  """
  def box_office(inputs, :absolute) do
    budget = inputs[:budget] || 0
    revenue = inputs[:revenue] || 0

    cond do
      budget > 0 and revenue > 0 ->
        revenue_score = min(1.0, :math.log(revenue + 1) / :math.log(1_000_000_000))
        roi_ratio = revenue / budget
        roi_score = min(1.0, :math.log(roi_ratio + 1) / :math.log(11))
        (revenue_score * 0.6 + roi_score * 0.4) * 10.0

      revenue > 0 ->
        min(10.0, :math.log(revenue + 1) / :math.log(1_000_000_000) * 10.0)

      true ->
        0.0
    end
  end

  def box_office(inputs, {:target, _source_key}) do
    budget = inputs[:tmdb_budget] || 0
    revenue = inputs[:tmdb_revenue] || 0

    if budget > 0 and revenue > 0 do
      roi = revenue / budget

      cond do
        roi >= 10.0 -> 25.0
        roi >= 5.0 -> 18.0
        roi >= 2.0 -> 12.0
        roi >= 1.0 -> 6.0
        true -> 0.0
      end
    else
      0.0
    end
  end

  # ── auteurs ──────────────────────────────────────────────────────────────

  @doc """
  People lens — mode-aware by design.

  Absolute: *intrinsic* role-weighted top-10 person quality, 0–10
  (`:person_quality` is the 0–100 value; divided by 10).

  Target: *relational* — the director's presence on the **target list**
  (`:director_target_count`) blended with the director's avg IMDb rating
  (`:director_avg_imdb`), 0–100. This is the list-relative signal that the
  target-blind discovery cache structurally cannot hold.
  """
  def auteurs(inputs, :absolute) do
    (inputs[:person_quality] || 0.0) / 10.0
  end

  def auteurs(inputs, {:target, _source_key}) do
    count = inputs[:director_target_count] || 0

    case inputs[:director_avg_imdb] do
      nil ->
        cond do
          count >= 5 -> 50.0
          count >= 3 -> 40.0
          count >= 1 -> 30.0
          true -> 0.0
        end

      avg_imdb ->
        rating_score = max(0.0, (avg_imdb - 5.0) / (9.0 - 5.0) * 100.0) |> min(100.0)
        count_bonus = min(count * 8.0, 40.0)
        min(rating_score * 0.65 + count_bonus, 100.0)
    end
  end

  # ── shared helpers ─────────────────────────────────────────────────────────

  @doc "Era vote multiplier: older films get fewer votes, so scale up their counts."
  def vote_scale_for_year(release_year) do
    cond do
      release_year < 1940 -> 5.0
      release_year < 1960 -> 3.0
      true -> 1.0
    end
  end

  # Era-aware IMDb critical mass, 0–25 (the popularity portion of cultural_impact).
  defp imdb_popularity_score(rating, votes, release_year) do
    scaled_votes = round((votes || 0) * vote_scale_for_year(release_year))

    cond do
      rating >= 7.5 and scaled_votes >= 100_000 -> 25.0
      rating >= 7.0 and scaled_votes >= 50_000 -> 17.0
      rating >= 6.5 and scaled_votes >= 25_000 -> 8.0
      true -> 0.0
    end
  end
end
