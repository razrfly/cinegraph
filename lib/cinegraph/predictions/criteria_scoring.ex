defmodule Cinegraph.Predictions.CriteriaScoring do
  @moduledoc """
  Implements the 5-criteria scoring system for predicting 1001 Movies list additions.

  The 5 criteria with default weights:
  1. The Mob (30%) - Audience ratings: IMDb, TMDb
  2. The Critics (20%) - Critic ratings: Metacritic, RT Tomatometer
  3. Festival Recognition (30%) - includes technical craft nominations
  4. Cultural Impact (15%)
  5. Auteur Recognition (5%)

  NOTE: This module uses its own 5-criterion vocabulary (festival_recognition,
  cultural_impact, auteur_recognition). The production scoring system
  (`Cinegraph.Metrics.ScoringService`) uses the same `festival_recognition` key
  as well as `auteurs` and `box_office`. These are two
  independent scoring subsystems: this one drives the predictions algorithm for
  future 1001 Movies additions; the other drives the discovery and disparity UIs.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Scoring.FestivalPrestige

  # Intentionally distinct from Cinegraph.Scoring.Lenses.all/0 — this system uses
  # cultural_impact and auteur_recognition instead of time_machine, box_office, and auteurs.
  @scoring_criteria ~w(mob critics festival_recognition cultural_impact auteur_recognition)a

  @default_weights %{
    mob: 0.30,
    critics: 0.20,
    festival_recognition: 0.30,
    cultural_impact: 0.15,
    auteur_recognition: 0.05
  }

  @named_profiles [
    %{
      name: "default",
      description: "Balanced — mob 30%, festival 30%, critics 20%, cultural 15%, auteur 5%",
      weights: @default_weights
    },
    %{
      name: "festival-heavy",
      description:
        "Festival-centric — festival 60%, mob/critics 10% each, cultural 15%, auteur 5%",
      weights: %{
        mob: 0.10,
        critics: 0.10,
        festival_recognition: 0.60,
        cultural_impact: 0.15,
        auteur_recognition: 0.05
      }
    },
    %{
      name: "audience-first",
      description:
        "Audience-driven — mob 35%, festival 25%, cultural 25%, critics 10%, auteur 5%",
      weights: %{
        mob: 0.35,
        critics: 0.10,
        festival_recognition: 0.25,
        cultural_impact: 0.25,
        auteur_recognition: 0.05
      }
    },
    %{
      name: "critics-choice",
      description:
        "Critic-weighted — critics 35%, festival 35%, cultural 15%, mob 10%, auteur 5%",
      weights: %{
        mob: 0.10,
        critics: 0.35,
        festival_recognition: 0.35,
        cultural_impact: 0.15,
        auteur_recognition: 0.05
      }
    },
    %{
      name: "auteur",
      description: "Director-focused — auteur 25%, festival 30%, mob/critics/cultural 15% each",
      weights: %{
        mob: 0.15,
        critics: 0.15,
        festival_recognition: 0.30,
        cultural_impact: 0.15,
        auteur_recognition: 0.25
      }
    }
  ]

  @doc "Returns the 5 prediction criteria atoms (distinct from Cinegraph.Scoring.Lenses)."
  def scoring_criteria, do: @scoring_criteria

  @doc """
  Get the default weights for the 5 criteria
  (mob, critics, festival_recognition, cultural_impact, auteur_recognition).
  """
  def get_default_weights, do: @default_weights

  @doc """
  Get all named weight profiles. Each profile is a map with :name, :description, and :weights keys.
  Profile names: "default", "festival-heavy", "audience-first", "critics-choice", "auteur"
  """
  def get_named_profiles, do: @named_profiles

  @doc """
  Look up a named profile by name. Returns nil if not found.
  """
  def get_profile(name), do: Enum.find(@named_profiles, &(&1.name == name))

  @doc """
  Get weights for a named profile. Returns default weights if name not found.
  """
  def get_profile_weights(name) do
    case get_profile(name) do
      nil -> @default_weights
      profile -> profile.weights
    end
  end

  @doc """
  Load ML-trained weights from movie_lists DB for a given source_key.
  Returns nil if no trained weights have been saved yet.
  Keys are strings (as stored in JSONB).
  """
  def get_trained_weights(source_key) do
    Cinegraph.Movies.MovieLists.get_trained_weights(source_key)
  end

  @doc """
  Batch score multiple movies efficiently to avoid N+1 query problems.
  Returns list of %{movie: movie, prediction: prediction} maps.
  """
  def batch_score_movies(movies, weights \\ @default_weights) do
    # Preload all external metrics for these movies
    movie_ids = Enum.map(movies, & &1.id)

    # Batch load external metrics
    external_metrics = batch_load_external_metrics(movie_ids)

    # Batch load festival nominations
    festival_nominations = batch_load_festival_nominations(movie_ids)

    # Batch load director info
    director_info = batch_load_director_info(movie_ids)

    # Score each movie using the batched data
    Enum.map(movies, fn movie ->
      prediction =
        calculate_movie_score_from_batch(
          movie,
          weights,
          external_metrics[movie.id] || [],
          festival_nominations[movie.id] || [],
          director_info[movie.id] || {0, nil}
        )

      %{movie: movie, prediction: prediction}
    end)
  end

  @doc """
  Calculate overall prediction score for a movie using weighted criteria.
  Returns score from 0-100 and detailed breakdown.
  """
  def calculate_movie_score(movie, weights \\ @default_weights) do
    scores = %{
      mob: score_mob(movie),
      critics: score_critics(movie),
      festival_recognition: score_festival_recognition(movie) || 0.0,
      cultural_impact: score_cultural_impact(movie) || 0.0,
      auteur_recognition: score_auteur_recognition(movie) || 0.0
    }

    weighted_total =
      Enum.reduce(scores, 0, fn {criterion, score}, acc ->
        score = score || 0.0
        weight = weights[criterion] || 0.0
        acc + score * weight
      end)

    %{
      total_score: Float.round(weighted_total, 1),
      likelihood_percentage: Float.round(convert_to_likelihood(weighted_total), 1),
      criteria_scores: scores,
      weights_used: weights,
      breakdown: calculate_breakdown(scores, weights)
    }
  end

  @doc """
  Score based on mob (audience ratings: IMDb, TMDb, RT Audience Score).
  Returns 0-100 score.
  """
  def score_mob(movie) do
    query =
      from em in "external_metrics",
        where: em.movie_id == ^movie.id,
        where:
          (em.source == "imdb" and em.metric_type == "rating_average") or
            (em.source == "tmdb" and em.metric_type == "rating_average") or
            (em.source == "imdb" and em.metric_type == "rating_votes"),
        select: [em.source, em.metric_type, em.value]

    score_mob_from_metrics(Repo.all(query), movie_release_year(movie))
  end

  @doc """
  Score based on critics (critic ratings: Metacritic, RT Tomatometer).
  Returns 0-100 score.
  """
  def score_critics(movie) do
    query =
      from em in "external_metrics",
        where: em.movie_id == ^movie.id,
        where:
          (em.source == "metacritic" and em.metric_type == "metascore") or
            (em.source == "rotten_tomatoes" and em.metric_type == "tomatometer"),
        select: [em.source, em.metric_type, em.value]

    score_critics_from_metrics(Repo.all(query))
  end

  @doc """
  Score based on festival recognition (wins/nominations at major festivals).
  Returns 0-100 score.
  """
  def score_festival_recognition(movie) do
    query =
      from fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        where: fnom.movie_id == ^movie.id,
        select: [fo.abbreviation, fc.name, fnom.won, fcer.year, fo.win_score, fo.nom_score]

    nominations = Repo.all(query)

    if length(nominations) == 0 do
      0.0
    else
      # Score each nomination and take the highest
      scores =
        Enum.map(nominations, fn [festival, category, won, year, win_score, nom_score] ->
          score_festival_nomination(%{
            festival: festival,
            category: category,
            won: won,
            year: year,
            win_score: win_score,
            nom_score: nom_score
          })
        end)

      min(Enum.sum(scores), 100.0)
    end
  end

  @doc """
  Score based on cultural impact (box office, budget ratio, cultural discourse).
  Returns 0-100 score.
  """
  def score_cultural_impact(movie) do
    # Extract box office and budget from TMDb data
    tmdb_data = movie.tmdb_data || %{}
    budget = get_in(tmdb_data, ["budget"]) || 0
    revenue = get_in(tmdb_data, ["revenue"]) || 0

    # Box office performance (0-25 points)
    roi_score =
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

    # Era-aware IMDb critical mass (0-25 points)
    popularity_score = imdb_popularity_score(get_imdb_popularity(movie), movie)

    # Canonical list presence (0-70 points, log-scaled) — primary signal, especially for pre-1960 films
    sources = Map.get(movie, :canonical_sources)
    canonical_count = if sources, do: map_size(sources), else: 0
    canonical_score = min(:math.log(1 + canonical_count) / :math.log(1 + 10) * 70.0, 70.0)

    min(roi_score + popularity_score + canonical_score, 100.0)
  end

  @doc """
  Score based on auteur recognition (director's existing 1001 Movies presence).
  Returns 0-100 score.
  """
  def score_auteur_recognition(movie) do
    # Get directors for this movie
    directors_query =
      from mc in "movie_credits",
        where: mc.movie_id == ^movie.id,
        where: mc.credit_type == "crew",
        where: mc.department == "Directing",
        select: mc.person_id

    director_ids = Repo.all(directors_query)

    if length(director_ids) == 0 do
      0.0
    else
      # Check how many movies by these directors are in 1001 Movies list
      existing_1001_query =
        from m in Movie,
          join: mc in "movie_credits",
          on: m.id == mc.movie_id,
          where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
          where: mc.person_id in ^director_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          select: count(m.id, :distinct)

      existing_1001_count = Repo.one(existing_1001_query) || 0

      # Score based on director's 1001 Movies presence
      cond do
        # Established auteur
        existing_1001_count >= 5 -> 100.0
        # Recognized auteur
        existing_1001_count >= 3 -> 80.0
        # Emerging auteur
        existing_1001_count >= 1 -> 60.0
        # Unknown director — no quality signal
        true -> 0.0
      end
    end
  end

  # Private helper functions

  defp convert_to_likelihood(weighted_score) do
    # Convert 0-100 weighted score to likelihood percentage
    # Use sigmoid-like curve to compress high scores toward 100%
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
    Enum.map(scores, fn {criterion, score} ->
      safe_score = score || 0.0
      safe_weight = weights[criterion] || 0.0

      %{
        criterion: criterion,
        raw_score: Float.round(safe_score, 1),
        weight: safe_weight,
        weighted_points: Float.round(safe_score * safe_weight, 1)
      }
    end)
  end

  defp normalize_rating_score("metacritic", "metascore", value) do
    # Metacritic metascore is already 0-100
    value || 0.0
  end

  defp normalize_rating_score("metacritic", "rating_average", value) do
    # Metacritic is already 0-100
    value || 0.0
  end

  defp normalize_rating_score("rotten_tomatoes", "audience_score", value) do
    # RT Audience Score is already 0-100; clamp to valid range
    max(0.0, min(100.0, value || 0.0))
  end

  defp normalize_rating_score("rotten_tomatoes", "tomatometer", value) do
    # RT Tomatometer is already 0-100
    value || 0.0
  end

  defp normalize_rating_score("rotten_tomatoes", "critics_score", value) do
    # RT Critics is already 0-100
    value || 0.0
  end

  defp normalize_rating_score("imdb", "rating_average", value) do
    # IMDB is 0-10, convert to 0-100
    (value || 0.0) * 10
  end

  defp normalize_rating_score("tmdb", "rating_average", value) do
    # TMDb is 0-10, convert to 0-100
    (value || 0.0) * 10
  end

  defp normalize_rating_score(_, _, value), do: value || 0.0

  defp score_festival_nomination(%{festival: festival, category: category, won: won} = attrs) do
    FestivalPrestige.score_nomination(
      festival,
      category,
      won,
      Map.get(attrs, :win_score),
      Map.get(attrs, :nom_score)
    )
  end

  defp get_imdb_popularity(movie) do
    query =
      from em in "external_metrics",
        where: em.movie_id == ^movie.id,
        where: em.source == "imdb",
        where: em.metric_type in ["rating_average", "rating_votes"],
        select: [em.metric_type, em.value]

    metrics = Repo.all(query)

    rating =
      Enum.find_value(metrics, 0.0, fn [metric_type, value] ->
        if metric_type == "rating_average", do: value, else: nil
      end)

    votes =
      Enum.find_value(metrics, 0, fn [metric_type, value] ->
        if metric_type == "rating_votes", do: round(value), else: nil
      end)

    {rating, votes}
  end

  # Batch loading functions for performance optimization

  # Runs query_fn on 500-ID chunks to avoid large IN-clause timeouts on big decades.
  defp batch_by_chunks(movie_ids, query_fn, chunk_size \\ 500) do
    movie_ids
    |> Enum.chunk_every(chunk_size)
    |> Enum.reduce(%{}, fn chunk_ids, acc ->
      Map.merge(acc, query_fn.(chunk_ids))
    end)
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

  defp batch_load_director_info(movie_ids) do
    # Step 1: chunk the movie_credits lookup by movie_id
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

    # Step 2: count 1001-list appearances per director (runs once on unique person_ids)
    all_director_ids = director_map |> Map.values() |> List.flatten() |> Enum.uniq()

    director_1001_counts =
      if length(all_director_ids) > 0 do
        all_director_ids
        |> Enum.chunk_every(500)
        |> Enum.reduce(%{}, fn chunk_ids, acc ->
          rows =
            from(m in Movie,
              join: mc in "movie_credits",
              on: m.id == mc.movie_id,
              where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
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
      else
        %{}
      end

    # Step 2b: avg IMDB rating per director across their full filmography (chunked)
    director_avg_ratings =
      if length(all_director_ids) > 0 do
        all_director_ids
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
            |> Map.new(fn {id, avg_val} ->
              avg =
                case avg_val do
                  nil -> nil
                  %Decimal{} = d -> d |> Decimal.to_float() |> Float.round(2)
                  f when is_float(f) -> Float.round(f, 2)
                  i when is_integer(i) -> Float.round(i * 1.0, 2)
                end

              {id, avg}
            end)

          Map.merge(acc, rows)
        end)
      else
        %{}
      end

    # Step 3: combine into {movie_id => {total_1001_count, director_avg_imdb_rating}}
    Map.new(director_map, fn {movie_id, director_ids} ->
      total_1001_count =
        director_ids
        |> Enum.map(&Map.get(director_1001_counts, &1, 0))
        |> Enum.sum()

      avg_imdb =
        director_ids
        |> Enum.map(&Map.get(director_avg_ratings, &1))
        |> Enum.reject(&is_nil/1)
        |> then(fn ratings ->
          if length(ratings) > 0, do: Enum.sum(ratings) / length(ratings), else: nil
        end)

      {movie_id, {total_1001_count, avg_imdb}}
    end)
  end

  defp movie_release_year(movie) do
    case movie do
      %{release_date: %Date{year: y}} -> y
      _ -> 2000
    end
  end

  defp cap100(nil), do: nil
  defp cap100(score), do: min(score, 100.0)

  defp calculate_movie_score_from_batch(
         movie,
         weights,
         external_metrics,
         festival_nominations,
         director_1001_count
       ) do
    # Use default weights if nil is passed
    actual_weights = weights || @default_weights

    all_nominations = festival_nominations

    # Calculate individual scores, ensuring they're all 0-100 range
    scores = %{
      mob: cap100(score_mob_from_metrics(external_metrics, movie_release_year(movie))),
      critics: cap100(score_critics_from_metrics(external_metrics)),
      festival_recognition:
        min(score_festival_recognition_from_batch(all_nominations) || 0.0, 100.0),
      cultural_impact:
        min(score_cultural_impact_from_batch(movie, external_metrics) || 0.0, 100.0),
      auteur_recognition:
        min(score_auteur_recognition_from_batch(director_1001_count) || 0.0, 100.0)
    }

    # Calculate weighted total (should be 0-100 since weights sum to 1.0)
    weighted_total =
      Enum.reduce(scores, 0.0, fn {criterion, score}, acc ->
        safe_score = min(score || 0.0, 100.0)
        weight = actual_weights[criterion] || 0.0
        acc + safe_score * weight
      end)

    # Ensure weighted_total is within valid range
    final_score = min(max(weighted_total, 0.0), 100.0)

    %{
      total_score: Float.round(final_score, 1),
      likelihood_percentage: Float.round(convert_to_likelihood(final_score), 1),
      criteria_scores: scores,
      weights_used: actual_weights,
      breakdown: calculate_breakdown(scores, actual_weights)
    }
  end

  defp score_mob_from_metrics(metrics, release_year) do
    rating_scores =
      metrics
      |> Enum.filter(fn [source, metric_type, _value] ->
        (source == "imdb" and metric_type == "rating_average") or
          (source == "tmdb" and metric_type == "rating_average")
      end)
      |> Enum.map(fn [source, metric_type, value] ->
        normalize_rating_score(source, metric_type, value || 0.0)
      end)
      |> Enum.filter(&(&1 > 0))

    imdb_votes =
      Enum.find_value(metrics, 0.0, fn
        ["imdb", "rating_votes", value] -> value || 0.0
        _ -> nil
      end) || 0.0

    if length(rating_scores) > 0 do
      avg_rating = Enum.sum(rating_scores) / length(rating_scores)
      rating_component = avg_rating * 0.70
      scaled_votes = imdb_votes * vote_scale_for_year(release_year)
      # log(1 + 100_000) ≈ 11.51 → 30 pts at 100K scaled votes
      vote_component = min(:math.log(1 + scaled_votes) / :math.log(1 + 100_000) * 30.0, 30.0)
      min(rating_component + vote_component, 100.0)
    else
      nil
    end
  end

  defp score_critics_from_metrics(metrics) do
    normalized_scores =
      metrics
      |> Enum.filter(fn [source, metric_type, _value] ->
        (source == "metacritic" and metric_type == "metascore") or
          (source == "rotten_tomatoes" and metric_type == "tomatometer")
      end)
      |> Enum.map(fn [source, metric_type, value] ->
        normalize_rating_score(source, metric_type, value || 0.0)
      end)
      |> Enum.filter(&(&1 > 0))

    if length(normalized_scores) > 0 do
      min(Enum.sum(normalized_scores) / length(normalized_scores), 100.0)
    else
      nil
    end
  end

  defp score_festival_recognition_from_batch(nominations) do
    if length(nominations) == 0 do
      0.0
    else
      # Score each nomination and take the highest, cap at 100
      scores =
        Enum.map(nominations, fn [festival, category, won, year, win_score, nom_score] ->
          min(
            score_festival_nomination(%{
              festival: festival,
              category: category,
              won: won,
              year: year,
              win_score: win_score,
              nom_score: nom_score
            }),
            100.0
          )
        end)

      min(Enum.sum(scores), 100.0)
    end
  end

  defp score_cultural_impact_from_batch(movie, metrics) do
    # Extract box office and budget from TMDb data
    tmdb_data = movie.tmdb_data || %{}
    budget = get_in(tmdb_data, ["budget"]) || 0
    revenue = get_in(tmdb_data, ["revenue"]) || 0

    # Box office performance (0-25 points)
    roi_score =
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

    # Era-aware IMDb critical mass (0-25 points)
    popularity_score = imdb_popularity_score(get_imdb_popularity_from_batch(metrics), movie)

    # Canonical list presence (0-70 points, log-scaled) — primary signal, especially for pre-1960 films
    sources = Map.get(movie, :canonical_sources)
    canonical_count = if sources, do: map_size(sources), else: 0
    canonical_score = min(:math.log(1 + canonical_count) / :math.log(1 + 10) * 70.0, 70.0)

    min(roi_score + popularity_score + canonical_score, 100.0)
  end

  # No IMDB data — fall back to 1001-count signal at half weight
  defp score_auteur_recognition_from_batch({director_1001_count, nil}) do
    cond do
      director_1001_count >= 5 -> 50.0
      director_1001_count >= 3 -> 40.0
      director_1001_count >= 1 -> 30.0
      true -> 0.0
    end
  end

  defp score_auteur_recognition_from_batch({director_1001_count, avg_imdb}) do
    # Continuous score: floor at 5.0, ceiling at 9.0
    rating_score = max(0.0, (avg_imdb - 5.0) / (9.0 - 5.0) * 100.0) |> min(100.0)
    # Bonus for 1001-list films (validates the auteur signal)
    count_bonus = min(director_1001_count * 8.0, 40.0)
    min(rating_score * 0.65 + count_bonus, 100.0)
  end

  # Backwards-compat for non-batch path (receives integer directly)
  defp score_auteur_recognition_from_batch(director_1001_count)
       when is_integer(director_1001_count) do
    score_auteur_recognition_from_batch({director_1001_count, nil})
  end

  defp vote_scale_for_year(release_year) do
    cond do
      release_year < 1940 -> 5.0
      release_year < 1960 -> 3.0
      true -> 1.0
    end
  end

  defp imdb_popularity_score({rating, votes}, movie) do
    release_year = movie_release_year(movie)
    scaled_votes = round(votes * vote_scale_for_year(release_year))

    cond do
      rating >= 7.5 and scaled_votes >= 100_000 -> 25.0
      rating >= 7.0 and scaled_votes >= 50_000 -> 17.0
      rating >= 6.5 and scaled_votes >= 25_000 -> 8.0
      true -> 0.0
    end
  end

  defp get_imdb_popularity_from_batch(metrics) do
    rating =
      Enum.find_value(metrics, 0.0, fn [source, metric_type, value] ->
        if source == "imdb" and metric_type == "rating_average", do: value, else: nil
      end)

    votes =
      Enum.find_value(metrics, 0, fn [source, metric_type, value] ->
        if source == "imdb" and metric_type == "rating_votes", do: round(value), else: nil
      end)

    {rating, votes}
  end
end
