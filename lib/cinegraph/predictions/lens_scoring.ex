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

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Metrics.ScoringService
  alias Cinegraph.Scoring.{LensFormulas, Lenses}

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
    movie_ids = Enum.map(movies, & &1.id)

    external_metrics = batch_load_external_metrics(movie_ids)
    festival_nominations = batch_load_festival_nominations(movie_ids)

    movies_on_target =
      for m <- movies,
          Map.has_key?(Map.get(m, :canonical_sources) || %{}, source_key),
          into: MapSet.new(),
          do: m.id

    director_info = batch_load_director_info(movie_ids, source_key, movies_on_target)

    Enum.map(movies, fn movie ->
      prediction =
        score_one(
          movie,
          weights,
          source_key,
          external_metrics[movie.id] || [],
          festival_nominations[movie.id] || [],
          director_info[movie.id] || {0, nil}
        )

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

  defp score_one(movie, weights, source_key, ext_metrics, festival_rows, director_info) do
    mode = {:target, source_key}
    inputs = build_inputs(movie, ext_metrics, director_info, source_key)

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

  defp build_inputs(movie, ext_metrics, {director_target_count, director_avg_imdb}, source_key) do
    tmdb_data = Map.get(movie, :tmdb_data) || %{}

    # Strip the target list before counting canonical presence (leakage guard).
    canonical_count =
      (Map.get(movie, :canonical_sources) || %{})
      |> Map.delete(source_key)
      |> map_size()

    %{
      imdb_rating: metric(ext_metrics, "imdb", "rating_average"),
      tmdb_rating: metric(ext_metrics, "tmdb", "rating_average"),
      imdb_votes: metric(ext_metrics, "imdb", "rating_votes") || 0.0,
      metacritic: metric(ext_metrics, "metacritic", "metascore"),
      rt_tomatometer: metric(ext_metrics, "rotten_tomatoes", "tomatometer"),
      canonical_count: canonical_count,
      release_year: movie_release_year(movie),
      tmdb_budget: get_in(tmdb_data, ["budget"]) || 0,
      tmdb_revenue: get_in(tmdb_data, ["revenue"]) || 0,
      director_target_count: director_target_count,
      director_avg_imdb: director_avg_imdb
    }
  end

  defp metric(ext_metrics, source, metric_type) do
    Enum.find_value(ext_metrics, fn
      [^source, ^metric_type, value] -> value
      _ -> nil
    end)
  end

  defp movie_release_year(%{release_date: %Date{year: y}}), do: y
  defp movie_release_year(_), do: 2000

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

  # ── batch loaders ────────────────────────────────────────────────────────

  defp batch_by_chunks(movie_ids, query_fn, chunk_size \\ 500) do
    movie_ids
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(%{}, fn chunk_ids, acc -> Map.merge(acc, query_fn.(chunk_ids)) end)
  end

  defp batch_load_external_metrics(movie_ids) do
    batch_by_chunks(movie_ids, fn chunk_ids ->
      from(em in "external_metrics",
        where: em.movie_id in ^chunk_ids,
        select: [em.movie_id, em.source, em.metric_type, em.value]
      )
      |> Repo.all(timeout: :timer.seconds(30))
      |> Enum.group_by(&hd/1, fn [_movie_id, source, metric_type, value] ->
        [source, metric_type, value]
      end)
    end)
  end

  defp batch_load_festival_nominations(movie_ids) do
    batch_by_chunks(movie_ids, fn chunk_ids ->
      from(fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        where: fnom.movie_id in ^chunk_ids,
        select: [
          fnom.movie_id,
          fo.abbreviation,
          fc.name,
          fnom.won,
          fcer.year,
          fo.win_score,
          fo.nom_score
        ]
      )
      |> Repo.all(timeout: :timer.seconds(30))
      |> Enum.group_by(&hd/1, fn [_movie_id, festival, category, won, year, win_score, nom_score] ->
        [festival, category, won, year, win_score, nom_score]
      end)
    end)
  end

  # Returns %{movie_id => {director_target_count, director_avg_imdb}} where the count
  # excludes the movie's own membership in `source_key` (leakage guard for `auteurs`).
  defp batch_load_director_info(movie_ids, source_key, movies_on_target) do
    director_map =
      batch_by_chunks(movie_ids, fn chunk_ids ->
        from(mc in "movie_credits",
          where: mc.movie_id in ^chunk_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          select: [mc.movie_id, mc.person_id]
        )
        |> Repo.all(timeout: :timer.seconds(30))
        |> Enum.group_by(&hd/1, fn [_movie_id, person_id] -> person_id end)
      end)

    all_director_ids = director_map |> Map.values() |> List.flatten() |> Enum.uniq()

    director_target_counts = director_target_counts(all_director_ids, source_key)
    director_avg_ratings = director_avg_ratings(all_director_ids)

    Map.new(director_map, fn {movie_id, director_ids} ->
      raw_count =
        director_ids
        |> Enum.map(&Map.get(director_target_counts, &1, 0))
        |> Enum.sum()

      # Exclude this movie's own contribution to its directors' counts.
      self_adjust =
        if MapSet.member?(movies_on_target, movie_id), do: length(director_ids), else: 0

      target_count = max(raw_count - self_adjust, 0)

      avg_imdb =
        director_ids
        |> Enum.map(&Map.get(director_avg_ratings, &1))
        |> Enum.reject(&is_nil/1)
        |> then(fn ratings ->
          if ratings == [], do: nil, else: Enum.sum(ratings) / length(ratings)
        end)

      {movie_id, {target_count, avg_imdb}}
    end)
  end

  defp director_target_counts([], _source_key), do: %{}

  defp director_target_counts(director_ids, source_key) do
    director_ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn chunk_ids, acc ->
      rows =
        from(m in Movie,
          join: mc in "movie_credits",
          on: m.id == mc.movie_id,
          where: fragment("? \\? ?", m.canonical_sources, ^source_key),
          where: mc.person_id in ^chunk_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          group_by: mc.person_id,
          select: {mc.person_id, count()}
        )
        |> Repo.all(timeout: :timer.seconds(30))
        |> Map.new()

      Map.merge(acc, rows)
    end)
  end

  defp director_avg_ratings([]), do: %{}

  defp director_avg_ratings(director_ids) do
    director_ids
    |> Enum.chunk_every(500)
    |> Enum.reduce(%{}, fn chunk_ids, acc ->
      rows =
        from(mc in "movie_credits",
          join: em in "external_metrics",
          on: em.movie_id == mc.movie_id,
          where: em.source == "imdb",
          where: em.metric_type == "rating_average",
          where: mc.person_id in ^chunk_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          group_by: mc.person_id,
          select: {mc.person_id, avg(em.value)}
        )
        |> Repo.all(timeout: :timer.seconds(30))
        |> Map.new(fn {id, avg_val} -> {id, to_rounded_float(avg_val)} end)

      Map.merge(acc, rows)
    end)
  end

  defp to_rounded_float(nil), do: nil
  defp to_rounded_float(%Decimal{} = d), do: d |> Decimal.to_float() |> Float.round(2)
  defp to_rounded_float(f) when is_float(f), do: Float.round(f, 2)
  defp to_rounded_float(i) when is_integer(i), do: Float.round(i * 1.0, 2)
end
