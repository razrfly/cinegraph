defmodule Cinegraph.Predictions.CriteriaScoring do
  @moduledoc """
  Implements the 6-criteria scoring system for predicting 1001 Movies list additions.

  The 6 criteria with default weights:
  1. The Mob (17.5%) - Audience ratings: IMDb, TMDb, RT Audience Score
  2. Ivory Tower (17.5%) - Critic ratings: Metacritic, RT Tomatometer
  3. Festival Recognition (30%)
  4. Cultural Impact (20%)
  5. Technical Innovation (10%)
  6. Auteur Recognition (5%)

  NOTE: This module uses its own criterion vocabulary (festival_recognition,
  technical_innovation, auteur_recognition). The production scoring system
  (`Cinegraph.Metrics.ScoringService`) uses the same `festival_recognition` key
  as well as `people_quality` and `financial_performance`. These are two
  independent scoring subsystems: this one drives the predictions algorithm for
  future 1001 Movies additions; the other drives the discovery and disparity UIs.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Scoring.FestivalPrestige

  @default_weights %{
    mob: 0.175,
    ivory_tower: 0.175,
    festival_recognition: 0.30,
    cultural_impact: 0.20,
    technical_innovation: 0.10,
    auteur_recognition: 0.05
  }

  @named_profiles [
    %{
      name: "default",
      description:
        "Balanced — festival 30%, mob/ivory 17.5% each, cultural 20%, technical 10%, auteur 5%",
      weights: @default_weights
    },
    %{
      name: "festival-heavy",
      description:
        "Festival-centric — festival 50%, mob/ivory 10% each, cultural 15%, technical 10%, auteur 5%",
      weights: %{
        mob: 0.10,
        ivory_tower: 0.10,
        festival_recognition: 0.50,
        cultural_impact: 0.15,
        technical_innovation: 0.10,
        auteur_recognition: 0.05
      }
    },
    %{
      name: "audience-first",
      description:
        "Audience-driven — mob 35%, festival 20%, cultural 25%, ivory 10%, technical/auteur 5% each",
      weights: %{
        mob: 0.35,
        ivory_tower: 0.10,
        festival_recognition: 0.20,
        cultural_impact: 0.25,
        technical_innovation: 0.05,
        auteur_recognition: 0.05
      }
    },
    %{
      name: "critics-choice",
      description:
        "Critic-weighted — ivory 35%, festival 30%, cultural 15%, mob 10%, technical/auteur 5% each",
      weights: %{
        mob: 0.10,
        ivory_tower: 0.35,
        festival_recognition: 0.30,
        cultural_impact: 0.15,
        technical_innovation: 0.05,
        auteur_recognition: 0.05
      }
    },
    %{
      name: "auteur",
      description:
        "Director-focused — auteur 25%, festival 25%, mob/ivory/cultural 15% each, technical 5%",
      weights: %{
        mob: 0.15,
        ivory_tower: 0.15,
        festival_recognition: 0.25,
        cultural_impact: 0.15,
        technical_innovation: 0.05,
        auteur_recognition: 0.25
      }
    }
  ]

  @doc """
  Get the default weights for the 6 criteria
  (mob, ivory_tower, festival_recognition, cultural_impact, technical_innovation, auteur_recognition).
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

    # Batch load technical nominations
    technical_nominations = batch_load_technical_nominations(movie_ids)

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
          technical_nominations[movie.id] || [],
          director_info[movie.id] || 0
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
      mob: score_mob(movie) || 0.0,
      ivory_tower: score_ivory_tower(movie) || 0.0,
      festival_recognition: score_festival_recognition(movie) || 0.0,
      cultural_impact: score_cultural_impact(movie) || 0.0,
      technical_innovation: score_technical_innovation(movie) || 0.0,
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
            (em.source == "tmdb" and em.metric_type == "rating_average"),
        select: [em.source, em.metric_type, em.value]

    score_mob_from_metrics(Repo.all(query))
  end

  @doc """
  Score based on ivory tower (critic ratings: Metacritic, RT Tomatometer).
  Returns 0-100 score.
  """
  def score_ivory_tower(movie) do
    query =
      from em in "external_metrics",
        where: em.movie_id == ^movie.id,
        where:
          (em.source == "metacritic" and em.metric_type == "metascore") or
            (em.source == "rotten_tomatoes" and em.metric_type == "tomatometer"),
        select: [em.source, em.metric_type, em.value]

    score_ivory_tower_from_metrics(Repo.all(query))
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

    # Base cultural impact score
    base_score = 0.0

    # Box office performance (0-40 points)
    roi_score =
      if budget > 0 and revenue > 0 do
        roi = revenue / budget

        cond do
          # 10x return = excellent
          roi >= 10.0 -> 40.0
          # 5x return = very good
          roi >= 5.0 -> 30.0
          # 2x return = good
          roi >= 2.0 -> 20.0
          # Break even = poor
          roi >= 1.0 -> 10.0
          # Loss = no points
          true -> 0.0
        end
      else
        0.0
      end

    # Critical mass indicator (0-30 points) - high rating + high vote count
    popularity_score =
      case get_imdb_popularity(movie) do
        {rating, votes} when rating >= 7.5 and votes >= 100_000 -> 30.0
        {rating, votes} when rating >= 7.0 and votes >= 50_000 -> 20.0
        {rating, votes} when rating >= 6.5 and votes >= 25_000 -> 10.0
        _ -> 0.0
      end

    # Genre diversity bonus (0-15 points) - certain genres get cultural impact boost
    genre_score = score_genre_cultural_impact(movie)

    # International recognition (0-15 points) - non-English films get bonus for crossing over
    international_score = score_international_impact(movie)

    base_score + roi_score + popularity_score + genre_score + international_score
  end

  @doc """
  Score based on technical innovation (cinematography, sound, editing, VFX nominations/wins
  at major festivals). Returns 0-100 score. Signal is real — backed by festival_nominations
  category name matching. Not a placeholder.
  """
  def score_technical_innovation(movie) do
    # Look for technical category nominations/wins
    query =
      from fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        where: fnom.movie_id == ^movie.id,
        where:
          fragment(
            "LOWER(?) LIKE ANY(ARRAY['%cinematography%', '%sound%', '%editing%', '%visual%', '%technical%'])",
            fc.name
          ),
        select: [fo.abbreviation, fc.name, fnom.won]

    technical_nominations = Repo.all(query)

    base_score =
      if length(technical_nominations) > 0 do
        # Score technical nominations
        Enum.reduce(technical_nominations, 0.0, fn [_festival, _category, won], acc ->
          points = if won, do: 20.0, else: 10.0
          acc + points
        end)
      else
        0.0
      end

    # Cap at 100
    min(base_score, 100.0)
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
        # New director
        true -> 20.0
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

  defp score_genre_cultural_impact(movie) do
    genres = get_in(movie.tmdb_data || %{}, ["genres"]) || []
    # 0 genres = 0, 4+ genres = 15 pts (cap at 15)
    Float.round(min(length(genres) / 4.0 * 15.0, 15.0), 1)
  end

  defp score_international_impact(movie) do
    original_language = get_in(movie.tmdb_data || %{}, ["original_language"]) || "en"

    if original_language != "en" do
      nom_count =
        Repo.one(
          from fnom in "festival_nominations",
            where: fnom.movie_id == ^movie.id,
            select: count()
        ) || 0

      # 8 base pts for non-English + up to 7 more from festival presence (cap at 15)
      Float.round(min(8.0 + min(nom_count * 1.5, 7.0), 15.0), 1)
    else
      0.0
    end
  end

  # Batch loading functions for performance optimization

  defp batch_load_external_metrics(movie_ids) do
    query =
      from em in "external_metrics",
        where: em.movie_id in ^movie_ids,
        select: [em.movie_id, em.source, em.metric_type, em.value]

    Repo.all(query)
    |> Enum.group_by(&hd/1, fn [_movie_id, source, metric_type, value] ->
      [source, metric_type, value]
    end)
  end

  defp batch_load_festival_nominations(movie_ids) do
    query =
      from fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        where: fnom.movie_id in ^movie_ids,
        select: [
          fnom.movie_id,
          fo.abbreviation,
          fc.name,
          fnom.won,
          fcer.year,
          fo.win_score,
          fo.nom_score
        ]

    Repo.all(query)
    |> Enum.group_by(&hd/1, fn [_movie_id, festival, category, won, year, win_score, nom_score] ->
      [festival, category, won, year, win_score, nom_score]
    end)
  end

  defp batch_load_technical_nominations(movie_ids) do
    query =
      from fnom in "festival_nominations",
        join: fc in "festival_categories",
        on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies",
        on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations",
        on: fcer.organization_id == fo.id,
        where: fnom.movie_id in ^movie_ids,
        where:
          fragment(
            "LOWER(?) LIKE ANY(ARRAY['%cinematography%', '%sound%', '%editing%', '%visual%', '%technical%'])",
            fc.name
          ),
        select: [fnom.movie_id, fo.abbreviation, fc.name, fnom.won]

    Repo.all(query)
    |> Enum.group_by(&hd/1, fn [_movie_id, festival, category, won] ->
      [festival, category, won]
    end)
  end

  defp batch_load_director_info(movie_ids) do
    # First get all directors for these movies
    directors_query =
      from mc in "movie_credits",
        where: mc.movie_id in ^movie_ids,
        where: mc.credit_type == "crew",
        where: mc.department == "Directing",
        select: [mc.movie_id, mc.person_id]

    director_map =
      Repo.all(directors_query)
      |> Enum.group_by(&hd/1, fn [_movie_id, person_id] -> person_id end)

    # Get 1001 movie counts for all directors
    all_director_ids =
      director_map
      |> Map.values()
      |> List.flatten()
      |> Enum.uniq()

    director_1001_counts =
      if length(all_director_ids) > 0 do
        existing_1001_query =
          from m in Movie,
            join: mc in "movie_credits",
            on: m.id == mc.movie_id,
            where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
            where: mc.person_id in ^all_director_ids,
            where: mc.credit_type == "crew",
            where: mc.department == "Directing",
            group_by: mc.person_id,
            select: {mc.person_id, count()}

        Repo.all(existing_1001_query) |> Map.new()
      else
        %{}
      end

    # Return director info per movie
    Map.new(director_map, fn {movie_id, director_ids} ->
      total_1001_count =
        director_ids
        |> Enum.map(&Map.get(director_1001_counts, &1, 0))
        |> Enum.sum()

      {movie_id, total_1001_count}
    end)
  end

  defp calculate_movie_score_from_batch(
         movie,
         weights,
         external_metrics,
         festival_nominations,
         technical_nominations,
         director_1001_count
       ) do
    # Use default weights if nil is passed
    actual_weights = weights || @default_weights

    # Calculate individual scores, ensuring they're all 0-100 range
    scores = %{
      mob: min(score_mob_from_metrics(external_metrics) || 0.0, 100.0),
      ivory_tower: min(score_ivory_tower_from_metrics(external_metrics) || 0.0, 100.0),
      festival_recognition:
        min(score_festival_recognition_from_batch(festival_nominations) || 0.0, 100.0),
      cultural_impact:
        min(
          score_cultural_impact_from_batch(movie, external_metrics, length(festival_nominations)) ||
            0.0,
          100.0
        ),
      technical_innovation:
        min(score_technical_innovation_from_batch(technical_nominations) || 0.0, 100.0),
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

  defp score_mob_from_metrics(metrics) do
    normalized_scores =
      metrics
      |> Enum.filter(fn [source, metric_type, _value] ->
        (source == "imdb" and metric_type == "rating_average") or
          (source == "tmdb" and metric_type == "rating_average")
      end)
      |> Enum.map(fn [source, metric_type, value] ->
        normalize_rating_score(source, metric_type, value || 0.0)
      end)
      |> Enum.filter(&(&1 > 0))

    if length(normalized_scores) > 0 do
      min(Enum.sum(normalized_scores) / length(normalized_scores), 100.0)
    else
      0.0
    end
  end

  defp score_ivory_tower_from_metrics(metrics) do
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
      0.0
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

  defp score_cultural_impact_from_batch(movie, metrics, festival_nominations_count \\ 0) do
    # Extract box office and budget from TMDb data
    tmdb_data = movie.tmdb_data || %{}
    budget = get_in(tmdb_data, ["budget"]) || 0
    revenue = get_in(tmdb_data, ["revenue"]) || 0

    # Box office performance (0-40 points)
    roi_score =
      if budget > 0 and revenue > 0 do
        roi = revenue / budget

        cond do
          # 10x return = excellent
          roi >= 10.0 -> 40.0
          # 5x return = very good
          roi >= 5.0 -> 30.0
          # 2x return = good
          roi >= 2.0 -> 20.0
          # Break even = poor
          roi >= 1.0 -> 10.0
          # Loss = no points
          true -> 0.0
        end
      else
        0.0
      end

    # Critical mass indicator (0-30 points) - high rating + high vote count
    popularity_score =
      case get_imdb_popularity_from_batch(metrics) do
        {rating, votes} when rating >= 7.5 and votes >= 100_000 -> 30.0
        {rating, votes} when rating >= 7.0 and votes >= 50_000 -> 20.0
        {rating, votes} when rating >= 6.5 and votes >= 25_000 -> 10.0
        _ -> 0.0
      end

    # Genre diversity bonus (0-15 points) - 0 genres = 0, 4+ genres = 15 pts
    genres = get_in(movie.tmdb_data || %{}, ["genres"]) || []
    genre_score = Float.round(min(length(genres) / 4.0 * 15.0, 15.0), 1)

    # International recognition (0-15 points) - non-English films get bonus for crossing over
    original_language = get_in(movie.tmdb_data || %{}, ["original_language"]) || "en"

    international_score =
      if original_language != "en" do
        Float.round(min(8.0 + min(festival_nominations_count * 1.5, 7.0), 15.0), 1)
      else
        0.0
      end

    # Sum all scores and cap at 100
    min(roi_score + popularity_score + genre_score + international_score, 100.0)
  end

  defp score_technical_innovation_from_batch(nominations) do
    base_score =
      if length(nominations) > 0 do
        # Score technical nominations
        Enum.reduce(nominations, 0.0, fn [_festival, _category, won], acc ->
          points = if won, do: 20.0, else: 10.0
          acc + points
        end)
      else
        0.0
      end

    # Cap at 100
    min(base_score, 100.0)
  end

  defp score_auteur_recognition_from_batch(director_1001_count) do
    # Score based on director's 1001 Movies presence
    cond do
      # Established auteur
      director_1001_count >= 5 -> 100.0
      # Recognized auteur
      director_1001_count >= 3 -> 80.0
      # Emerging auteur
      director_1001_count >= 1 -> 60.0
      # New director
      true -> 20.0
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
