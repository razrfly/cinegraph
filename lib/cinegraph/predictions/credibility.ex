defmodule Cinegraph.Predictions.Credibility do
  @moduledoc """
  The credibility engine (#1036 Session 3) — measures a model honestly on a held-out slice.

  Re-homes the recall@K logic from the retired `Calibration.RecallCalculator` (git `8bd5c4a^`),
  generalized to score via the Layer-2 `Bus` so it works for any granularity (lens or
  data-point), plus precision@K, Brier, per-decade breakdown, worst-miss, and dumb baselines.

  `recall@K` per decade: rank the decade's movies by score, take the top N (N = number of
  actual list members in that decade), and measure how many members land in that top N. This
  is the "if we predicted exactly as many as really exist, how many did we get" question.

  Produces the JSON-able `integrity_report` stored on the model. Designed to run on the
  **sacred holdout** (latest decade), so the numbers are out-of-sample.
  """

  alias Cinegraph.Predictions.ProbabilityCalibration
  alias Cinegraph.Repo
  alias Cinegraph.Scoring.Bus

  @doc """
  Evaluate `spec` (a `%Model{}` or a `{granularity, weights, source_key}` Bus spec) on the
  given `decades`. Returns a JSON-able report plus the raw `(score, label)` pairs (for
  downstream calibration). `popularity`/`prior_rate`/`random` baselines are scored the same
  way for honest comparison.
  """
  def evaluate(spec, source_key, decades, opts \\ []) do
    seed = Keyword.get(opts, :seed, 1337)
    per_decade_movies = Enum.map(decades, fn d -> {d, labeled_movies(d, source_key)} end)

    decade_reports =
      Enum.map(per_decade_movies, fn {decade, labeled} ->
        scored = score_labeled(spec, labeled)
        rp = recall_precision_at_k(scored)
        Map.merge(%{"decade" => decade}, rp)
      end)

    all_scored =
      Enum.flat_map(per_decade_movies, fn {_d, labeled} -> score_labeled(spec, labeled) end)

    overall = recall_precision_at_k(all_scored)
    pairs = Enum.map(all_scored, fn s -> {s.score, s.label} end)

    %{
      "recall_at_k" => overall["recall_at_k"],
      "precision_at_k" => overall["precision_at_k"],
      "n_positives" => overall["n_positives"],
      "n_evaluated" => length(all_scored),
      "by_decade" => decade_reports,
      "worst_miss" => worst_miss(all_scored),
      "baselines" => baselines(per_decade_movies, source_key, seed),
      "pairs" => pairs
    }
  end

  @doc "Brier score = mean((p − y)²) over calibrated probabilities."
  def brier(probs, labels) when length(probs) == length(labels) do
    n = length(labels)

    if n == 0 do
      nil
    else
      sum =
        Enum.zip(probs, labels)
        |> Enum.reduce(0.0, fn {p, y}, acc -> acc + :math.pow(p - y, 2) end)

      Float.round(sum / n, 4)
    end
  end

  @doc "Brier from raw bus scores + a calibration map (applies it first)."
  def brier_calibrated(pairs, calibration) do
    {scores, labels} = Enum.unzip(pairs)
    probs = Enum.map(scores, &ProbabilityCalibration.apply_calibration(calibration, &1))
    brier(probs, labels)
  end

  # ── internals ────────────────────────────────────────────────────────────────

  defp labeled_movies(decade, source_key) do
    movies = Repo.all(Cinegraph.Movies.decade_movies_query(decade), timeout: :timer.seconds(120))

    Enum.map(movies, fn m ->
      label = if Map.has_key?(m.canonical_sources || %{}, source_key), do: 1, else: 0
      {m, label}
    end)
  end

  @doc "Score `[{movie, label}]` via the bus → `[%{movie_id, title, score, label}]`."
  def score_labeled(spec, labeled) do
    movies = Enum.map(labeled, fn {m, _} -> m end)
    scores = Bus.score(movies, spec)

    Enum.map(labeled, fn {m, label} ->
      %{movie_id: m.id, title: m.title, score: Map.get(scores, m.id, 0.0), label: label}
    end)
  end

  @doc "recall@K and precision@K where K = number of positives in the scored set."
  def recall_precision_at_k(scored) do
    n_pos = Enum.count(scored, &(&1.label == 1))

    if n_pos == 0 do
      %{"recall_at_k" => nil, "precision_at_k" => nil, "n_positives" => 0}
    else
      top = scored |> Enum.sort_by(& &1.score, :desc) |> Enum.take(n_pos)
      hits = Enum.count(top, &(&1.label == 1))

      %{
        "recall_at_k" => Float.round(hits / n_pos, 4),
        "precision_at_k" => Float.round(hits / n_pos, 4),
        "n_positives" => n_pos
      }
    end
  end

  @doc "The most-missed member (lowest-scored) and worst false positive (highest-scored non-member)."
  def worst_miss(scored) do
    members = Enum.filter(scored, &(&1.label == 1))
    nonmembers = Enum.filter(scored, &(&1.label == 0))

    %{
      "lowest_scored_member" => brief(Enum.min_by(members, & &1.score, fn -> nil end)),
      "highest_scored_nonmember" => brief(Enum.max_by(nonmembers, & &1.score, fn -> nil end))
    }
  end

  defp brief(nil), do: nil

  defp brief(%{title: t, score: s, movie_id: id}),
    do: %{"title" => t, "score" => s, "movie_id" => id}

  # Dumb baselines, scored exactly like the model (recall@K), for honest comparison.
  defp baselines(per_decade_movies, source_key, seed) do
    pop_spec = {:data_point, %{"tmdb_popularity_score" => 1.0}, source_key}

    pop =
      overall_recall(per_decade_movies, fn labeled -> score_labeled(pop_spec, labeled) end)

    :rand.seed(:exsss, {seed, seed, seed})

    rand =
      overall_recall(per_decade_movies, fn labeled ->
        Enum.map(labeled, fn {m, label} ->
          %{movie_id: m.id, title: m.title, score: :rand.uniform(), label: label}
        end)
      end)

    %{
      "popularity" => pop,
      "random" => rand,
      # all-equal scores ⇒ top-K is arbitrary ⇒ expected recall = base rate
      "prior_rate" => base_rate(per_decade_movies)
    }
  end

  defp overall_recall(per_decade_movies, score_fn) do
    all = Enum.flat_map(per_decade_movies, fn {_d, labeled} -> score_fn.(labeled) end)
    recall_precision_at_k(all)["recall_at_k"]
  end

  defp base_rate(per_decade_movies) do
    {pos, total} =
      Enum.reduce(per_decade_movies, {0, 0}, fn {_d, labeled}, {p, t} ->
        {p + Enum.count(labeled, fn {_m, l} -> l == 1 end), t + length(labeled)}
      end)

    if total == 0, do: nil, else: Float.round(pos / total, 4)
  end
end
