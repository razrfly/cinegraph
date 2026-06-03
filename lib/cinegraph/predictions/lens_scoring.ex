defmodule Cinegraph.Predictions.LensScoring do
  @moduledoc """
  Target-mode scoring over the unified 6-lens vocabulary — the prediction engine.

  Replaces the former standalone 5-criterion prediction scorer. Computes the six lenses
  (`mob, critics, festival_recognition, time_machine, auteurs, box_office`) via the
  shared `Cinegraph.Scoring.LensFormulas` in `{:target, source_key}` mode, against
  an arbitrary target list (not just `1001_movies`).

  ## Leakage safety (intrinsic, not the caller's job)

  Callers pass movies with their **full** `canonical_sources`; this module does all
  target-stripping so a movie's score for list `L` is independent of whether `L`
  is in its `canonical_sources`:

    * `time_machine` — `source_key` is removed before counting canonical lists.
    * `auteurs` — the director track-record count excludes the movie's own
      membership in `L` (the old code leaked here: a movie on `L` inflated its own
      director's count).

  ## Public surface

  Preserves the former scorer.s public contract so callers change minimally; each
  scoring entry point gains a `source_key` argument. `criteria_scores` now holds the
  6 lens keys. Scores are on a 0–100 scale; `likelihood_percentage` is unchanged.
  """

  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Scoring.{FeatureResolver, LensFormulas, Lenses}

  @default_source_key "1001_movies"

  # The 6-lens vocabulary — single source of truth in Cinegraph.Scoring.Lenses.
  @criteria Lenses.all()
  @default_weights Lenses.default_atom_weights()

  # Used only when the DB has no active metric_weight_profiles (e.g. the test
  # sandbox). In production `get_named_profiles/0` reads the DB profile store.
  @fallback_named_profiles [
    %{
      name: "default",
      description: "Balanced six-lens weighting (Cinegraph.Scoring.Lenses defaults)",
      weights: @default_weights
    },
    %{
      name: "festival-heavy",
      description: "Festival-centric",
      weights: %{
        mob: 0.10,
        critics: 0.10,
        festival_recognition: 0.50,
        time_machine: 0.15,
        auteurs: 0.10,
        box_office: 0.05
      }
    },
    %{
      name: "audience-first",
      description: "Audience-driven",
      weights: %{
        mob: 0.35,
        critics: 0.10,
        festival_recognition: 0.20,
        time_machine: 0.20,
        auteurs: 0.10,
        box_office: 0.05
      }
    },
    %{
      name: "critics-choice",
      description: "Critic-weighted",
      weights: %{
        mob: 0.10,
        critics: 0.35,
        festival_recognition: 0.30,
        time_machine: 0.15,
        auteurs: 0.05,
        box_office: 0.05
      }
    },
    %{
      name: "auteur",
      description: "Director/canon-focused",
      weights: %{
        mob: 0.10,
        critics: 0.10,
        festival_recognition: 0.25,
        time_machine: 0.20,
        auteurs: 0.30,
        box_office: 0.05
      }
    }
  ]

  @doc "Returns the 6 lens atoms (the unified vocabulary)."
  def scoring_criteria, do: @criteria

  @doc "Default six-lens weights (sum to 1.0)."
  def get_default_weights, do: @default_weights

  @doc """
  All named six-lens weight profiles. Reads the shared DB profile store
  (`metric_weight_profiles`), converting each to six-lens atom weights normalized
  to sum to 1.0. Falls back to a built-in set when the DB has no active profiles.
  """
  def get_named_profiles do
    case db_named_profiles() do
      [] -> @fallback_named_profiles
      profiles -> profiles
    end
  end

  defp db_named_profiles do
    ScoringService.get_all_profiles()
    |> Enum.map(fn p ->
      %{
        name: p.name,
        description: p.description || "",
        weights: normalize_weights(ScoringService.profile_to_discovery_weights(p))
      }
    end)
  rescue
    _ -> []
  end

  defp normalize_weights(weights) do
    total = weights |> Map.values() |> Enum.sum()
    if total > 0, do: Map.new(weights, fn {k, v} -> {k, v / total} end), else: weights
  end

  @doc "Look up a named profile by name; nil if not found."
  def get_profile(name), do: Enum.find(get_named_profiles(), &(&1.name == name))

  @doc "Weights for a named profile, or defaults if not found."
  def get_profile_weights(name) do
    case get_profile(name) do
      nil -> @default_weights
      profile -> profile.weights
    end
  end

  @doc """
  Load ML-trained weights from movie_lists DB for a given source_key.
  Returns nil if none saved yet. Keys are strings (JSONB).
  """
  def get_trained_weights(source_key) do
    Cinegraph.Movies.MovieLists.get_trained_weights(source_key)
  end

  @doc """
  Batch score movies in Target mode against `source_key`.
  Returns `[%{movie: movie, prediction: prediction}]`. Pass movies with full
  `canonical_sources` — stripping is handled here.
  """
  def batch_score_movies(movies, weights \\ @default_weights, source_key \\ @default_source_key) do
    weights = weights || @default_weights
    mode = {:target, source_key}

    # The FeatureResolver builds the (leakage-stripped) target inputs; the scoring math
    # below is unchanged (#1036 Session 1).
    bundles = FeatureResolver.resolve_batch(movies, mode)

    Enum.map(movies, fn movie ->
      prediction = score_one(weights, mode, Map.fetch!(bundles, movie.id))
      %{movie: movie, prediction: prediction}
    end)
  end

  @doc """
  Score a single movie in Target mode. Movie must carry full `canonical_sources`
  and (for `box_office`) `tmdb_data`.
  """
  def calculate_movie_score(movie, weights \\ @default_weights, source_key \\ @default_source_key) do
    [%{prediction: prediction}] = batch_score_movies([movie], weights, source_key)
    prediction
  end

  # ── scoring ────────────────────────────────────────────────────────────────

  defp score_one(weights, mode, %{inputs: inputs, festival_rows: festival_rows}) do
    scores = %{
      mob: cap100(LensFormulas.mob(inputs, mode)) || 0.0,
      critics: cap100(LensFormulas.critics(inputs, mode)) || 0.0,
      festival_recognition: min(LensFormulas.festival(festival_rows, mode) || 0.0, 100.0),
      time_machine: min(LensFormulas.time_machine(inputs, mode) || 0.0, 100.0),
      auteurs: min(LensFormulas.auteurs(inputs, mode) || 0.0, 100.0),
      box_office: min(LensFormulas.box_office(inputs, mode) || 0.0, 100.0)
    }

    weighted_total =
      Enum.reduce(scores, 0.0, fn {lens, score}, acc ->
        acc + min(score || 0.0, 100.0) * (weights[lens] || 0.0)
      end)

    final_score = min(max(weighted_total, 0.0), 100.0)

    %{
      total_score: Float.round(final_score, 1),
      likelihood_percentage: Float.round(convert_to_likelihood(final_score), 1),
      criteria_scores: scores,
      weights_used: weights,
      breakdown: calculate_breakdown(scores, weights)
    }
  end

  defp cap100(nil), do: nil
  defp cap100(score), do: min(score, 100.0)

  defp convert_to_likelihood(weighted_score) do
    score = weighted_score || 0.0

    cond do
      score >= 90 -> 95 + (score - 90) * 0.5
      score >= 80 -> 85 + (score - 80) * 1.0
      score >= 70 -> 70 + (score - 70) * 1.5
      score >= 60 -> 55 + (score - 60) * 1.5
      true -> score * 0.9
    end
  end

  defp calculate_breakdown(scores, weights) do
    Enum.map(scores, fn {lens, score} ->
      safe_score = score || 0.0
      safe_weight = weights[lens] || 0.0

      %{
        criterion: lens,
        raw_score: Float.round(safe_score, 1),
        weight: safe_weight,
        weighted_points: Float.round(safe_score * safe_weight, 1)
      }
    end)
  end
end
