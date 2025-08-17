defmodule Cinegraph.Predictions.CriteriaScoring do
  @moduledoc """
  Implements the 5-criteria scoring system for predicting 1001 Movies list additions.
  
  The 5 criteria with default weights:
  1. Critical Acclaim (35%)
  2. Festival Recognition (30%) 
  3. Cultural Impact (20%)
  4. Technical Innovation (10%)
  5. Auteur Recognition (5%)
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie

  @default_weights %{
    critical_acclaim: 0.35,
    festival_recognition: 0.30,
    cultural_impact: 0.20,
    technical_innovation: 0.10,
    auteur_recognition: 0.05
  }

  @doc """
  Get the default weights for the 5 criteria.
  """
  def get_default_weights, do: @default_weights

  @doc """
  Calculate overall prediction score for a movie using weighted criteria.
  Returns score from 0-100 and detailed breakdown.
  """
  def calculate_movie_score(movie, weights \\ @default_weights) do
    scores = %{
      critical_acclaim: score_critical_acclaim(movie) || 0.0,
      festival_recognition: score_festival_recognition(movie) || 0.0,
      cultural_impact: score_cultural_impact(movie) || 0.0,
      technical_innovation: score_technical_innovation(movie) || 0.0,
      auteur_recognition: score_auteur_recognition(movie) || 0.0
    }

    weighted_total = 
      Enum.reduce(scores, 0, fn {criterion, score}, acc ->
        score = score || 0.0
        weight = weights[criterion] || 0.0
        acc + (score * weight)
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
  Score based on critical acclaim (Metacritic, RT Critics, awards).
  Returns 0-100 score.
  """
  def score_critical_acclaim(movie) do
    query = 
      from em in "external_metrics",
        where: em.movie_id == ^movie.id,
        where: em.source in ["metacritic", "rotten_tomatoes", "imdb"],
        where: em.metric_type in ["rating_average", "critics_score"],
        select: [em.source, em.metric_type, em.value]

    metrics = Repo.all(query)
    
    if length(metrics) == 0 do
      0.0
    else
      # Convert all scores to 0-100 scale and average
      normalized_scores = 
        Enum.map(metrics, fn [source, metric_type, value] ->
          normalize_critic_score(source, metric_type, value)
        end)
        
      Enum.sum(normalized_scores) / length(normalized_scores)
    end
  end

  @doc """
  Score based on festival recognition (wins/nominations at major festivals).
  Returns 0-100 score.
  """
  def score_festival_recognition(movie) do
    query =
      from fnom in "festival_nominations",
        join: fc in "festival_categories", on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies", on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations", on: fcer.organization_id == fo.id,
        where: fnom.movie_id == ^movie.id,
        select: [fo.abbreviation, fc.name, fnom.won, fcer.year]

    nominations = Repo.all(query)
    
    if length(nominations) == 0 do
      0.0
    else
      # Score each nomination and take the highest
      scores = Enum.map(nominations, fn [festival, category, won, year] ->
        score_festival_nomination(%{festival: festival, category: category, won: won, year: year})
      end)
      Enum.max(scores, fn -> 0.0 end)
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
    roi_score = if budget > 0 and revenue > 0 do
      roi = revenue / budget
      cond do
        roi >= 10.0 -> 40.0  # 10x return = excellent
        roi >= 5.0 -> 30.0   # 5x return = very good
        roi >= 2.0 -> 20.0   # 2x return = good
        roi >= 1.0 -> 10.0   # Break even = poor
        true -> 0.0          # Loss = no points
      end
    else
      0.0
    end
    
    # Critical mass indicator (0-30 points) - high rating + high vote count
    popularity_score = case get_imdb_popularity(movie) do
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
  Score based on technical innovation (technical awards, breakthrough techniques).
  Returns 0-100 score.
  """
  def score_technical_innovation(movie) do
    # Look for technical category nominations/wins
    query =
      from fnom in "festival_nominations",
        join: fc in "festival_categories", on: fnom.category_id == fc.id,
        join: fcer in "festival_ceremonies", on: fnom.ceremony_id == fcer.id,
        join: fo in "festival_organizations", on: fcer.organization_id == fo.id,
        where: fnom.movie_id == ^movie.id,
        where: fragment("LOWER(?) LIKE ANY(ARRAY['%cinematography%', '%sound%', '%editing%', '%visual%', '%technical%'])", fc.name),
        select: [fo.abbreviation, fc.name, fnom.won]

    technical_nominations = Repo.all(query)
    
    base_score = if length(technical_nominations) > 0 do
      # Score technical nominations
      Enum.reduce(technical_nominations, 0.0, fn [festival, category, won], acc ->
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
          join: mc in "movie_credits", on: m.id == mc.movie_id,
          where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
          where: mc.person_id in ^director_ids,
          where: mc.credit_type == "crew",
          where: mc.department == "Directing",
          select: count()

      existing_1001_count = Repo.one(existing_1001_query) || 0
      
      # Score based on director's 1001 Movies presence
      cond do
        existing_1001_count >= 5 -> 100.0  # Established auteur
        existing_1001_count >= 3 -> 80.0   # Recognized auteur
        existing_1001_count >= 1 -> 60.0   # Emerging auteur
        true -> 20.0                       # New director
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

  defp normalize_critic_score("metacritic", "rating_average", value) do
    # Metacritic is already 0-100
    value
  end

  defp normalize_critic_score("rotten_tomatoes", "critics_score", value) do
    # RT Critics is already 0-100
    value
  end

  defp normalize_critic_score("imdb", "rating_average", value) do
    # IMDB is 0-10, convert to 0-100
    value * 10
  end

  defp normalize_critic_score(_, _, value), do: value

  defp score_festival_nomination(%{festival: festival, won: won, category: category}) do
    base_score = case festival do
      "AMPAS" -> if won, do: 100.0, else: 80.0  # Oscars
      "CANNES" -> if won, do: 95.0, else: 75.0   # Cannes
      "VIFF" -> if won, do: 90.0, else: 70.0     # Venice
      "BIFF" -> if won, do: 90.0, else: 70.0     # Berlin  
      "SUNDANCE" -> if won, do: 75.0, else: 60.0 # Sundance
      _ -> if won, do: 50.0, else: 30.0          # Other festivals
    end
    
    # Boost for prestigious categories
    category_boost = if String.contains?(String.downcase(category), ["picture", "film", "director"]) do
      10.0
    else
      0.0
    end
    
    base_score + category_boost
  end

  defp get_imdb_popularity(movie) do
    query =
      from em in "external_metrics",
        where: em.movie_id == ^movie.id,
        where: em.source == "imdb",
        where: em.metric_type in ["rating_average", "rating_votes"],
        select: [em.metric_type, em.value]

    metrics = Repo.all(query)
    
    rating = Enum.find_value(metrics, 0.0, fn [metric_type, value] -> 
      if metric_type == "rating_average", do: value, else: nil 
    end)
    
    votes = Enum.find_value(metrics, 0, fn [metric_type, value] -> 
      if metric_type == "rating_votes", do: round(value), else: nil 
    end)
    
    {rating, votes}
  end

  defp score_genre_cultural_impact(movie) do
    # This would need to query movie genres and apply cultural impact scores
    # For now, return base score
    10.0
  end

  defp score_international_impact(movie) do
    # Check if non-English film with significant recognition
    # For now, return base score  
    5.0
  end
end