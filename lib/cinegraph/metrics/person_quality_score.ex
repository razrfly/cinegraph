defmodule Cinegraph.Metrics.PersonQualityScore do
  @moduledoc """
  Calculates and stores Person Quality Scores (PQS) using universal algorithm.
  
  Works for all roles (directors, actors, writers, producers, etc.) using objective measurements:
  - Canonical list appearances (1001 Movies, Criterion, NFR, Sight & Sound)
  - High-rated films (IMDb/TMDb >= 7.0)
  - Festival recognition (nominations and wins)
  - Total film volume (productivity)
  
  Formula: (Canonical × 10) + (High Rated × 3) + (Total × 1) + (Festival Wins × 15) + (Festival Noms × 5)
  """
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.People
  alias Cinegraph.Movies.Movie
  alias Cinegraph.Metrics.PersonMetric
  
  # Scoring weights
  @canonical_weight 10
  @high_rated_weight 3
  @volume_weight 1
  @festival_win_weight 15
  @festival_nom_weight 5
  @high_rating_threshold 7.0
  
  @doc """
  Calculate universal quality score for any person based on objective film achievements.
  Returns a normalized score between 0 and 100.
  """
  @spec calculate_person_score(integer()) :: {:ok, float(), map()} | {:error, any()}
  def calculate_person_score(person_id) do
    try do
      # Get all movies this person worked on (any role)
      person_movies = get_person_movies(person_id)
      
      if Enum.empty?(person_movies) do
        components = %{
          "canonical_count" => 0,
          "high_rated_count" => 0,
          "total_count" => 0,
          "festival_wins" => 0,
          "festival_nominations" => 0,
          "raw_score" => 0
        }
        {:ok, 0.0, components}
      else
        # Count objective achievements
        canonical_count = count_canonical_appearances(person_movies)
        high_rated_count = count_high_rated_movies(person_movies)
        festival_nominations = count_festival_nominations(person_id)
        festival_wins = count_festival_wins(person_id)
        total_count = length(person_movies)
        
        # Calculate weighted score
        raw_score = (canonical_count * @canonical_weight) +
                    (high_rated_count * @high_rated_weight) +
                    (total_count * @volume_weight) +
                    (festival_wins * @festival_win_weight) +
                    (festival_nominations * @festival_nom_weight)
        
        # Normalize to 0-100 range using adaptive scaling
        normalized_score = normalize_score(raw_score, total_count)
        
        components = %{
          "canonical_count" => canonical_count,
          "high_rated_count" => high_rated_count,
          "total_count" => total_count,
          "festival_wins" => festival_wins,
          "festival_nominations" => festival_nominations,
          "raw_score" => raw_score
        }
        
        {:ok, Float.round(normalized_score, 2), components}
      end
    rescue
      error ->
        {:error, error}
    end
  end
  
  @doc """
  Store person quality score in person_metrics table.
  """
  def store_person_score(person_id, score, components \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    attrs = %{
      person_id: person_id,
      metric_type: "quality_score",
      score: score,
      components: components,
      metadata: %{
        "version" => "2.0",
        "algorithm" => "universal_objective",
        "weights" => %{
          "canonical" => @canonical_weight,
          "high_rated" => @high_rated_weight,
          "volume" => @volume_weight,
          "festival_wins" => @festival_win_weight,
          "festival_nominations" => @festival_nom_weight
        }
      },
      calculated_at: now,
      valid_until: DateTime.add(now, 7, :day)  # Recalculate weekly
    }
    
    %PersonMetric{}
    |> PersonMetric.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:score, :components, :metadata, :calculated_at, :valid_until, :updated_at]},
      conflict_target: [:person_id, :metric_type]
    )
  end
  
  @doc """
  Calculate scores for all people with significant film involvement (>= 5 credits).
  """
  @spec calculate_all_person_scores(integer()) :: {:ok, map()} | {:error, any()}
  def calculate_all_person_scores(min_credits \\ 5) do
    try do
      # Get all people with significant film involvement
      people_with_credits = get_people_with_min_credits(min_credits)
      
      results = Enum.map(people_with_credits, fn person ->
        case calculate_person_score(person.id) do
          {:ok, score, components} ->
            case store_person_score(person.id, score, components) do
              {:ok, _} -> {:ok, person.id, score}
              error -> {:error, person.id, error}
            end
          {:error, error} -> 
            {:error, person.id, error}
        end
      end)
      
      successful = Enum.filter(results, fn 
        {:ok, _, _} -> true
        _ -> false
      end)
      
      {:ok, %{
        total: length(results),
        successful: length(successful),
        results: results
      }}
    rescue
      error ->
        {:error, error}
    end
  end
  
  @doc """
  Get top people by quality score.
  """
  def get_top_people(limit \\ 10) do
    from(pm in PersonMetric,
      where: pm.metric_type == "quality_score",
      order_by: [desc: pm.score],
      limit: ^limit,
      select: %{
        person_id: pm.person_id,
        score: pm.score,
        components: pm.components,
        updated_at: pm.updated_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn result ->
      # Fetch person details
      person = People.get_person!(result.person_id)
      Map.put(result, :person, person)
    end)
  end
  
  @doc """
  Get top people by role (for analysis).
  """
  def get_top_people_by_role(role, limit \\ 10) do
    # Get people who have worked in this role
    person_ids = from(mc in "movie_credits",
      where: mc.department == ^role or mc.job == ^role,
      distinct: [mc.person_id],
      select: mc.person_id
    )
    |> Repo.all()
    
    from(pm in PersonMetric,
      where: pm.metric_type == "quality_score" and pm.person_id in ^person_ids,
      order_by: [desc: pm.score],
      limit: ^limit,
      select: %{
        person_id: pm.person_id,
        score: pm.score,
        components: pm.components,
        updated_at: pm.updated_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn result ->
      person = People.get_person!(result.person_id)
      Map.put(result, :person, person)
    end)
  end
  
  # Private functions
  
  defp get_person_movies(person_id) do
    from(mc in "movie_credits",
      where: mc.person_id == ^person_id,
      join: m in Movie, on: m.id == mc.movie_id,
      distinct: [m.id],
      select: m
    )
    |> Repo.all()
  end
  
  defp get_people_with_min_credits(min_credits) do
    from(mc in "movie_credits",
      group_by: mc.person_id,
      having: count(mc.movie_id) >= ^min_credits,
      select: %{id: mc.person_id}
    )
    |> Repo.all()
    |> Enum.map(fn %{id: person_id} -> 
      People.get_person!(person_id)
    end)
  end
  
  defp count_canonical_appearances(movies) do
    movie_ids = Enum.map(movies, & &1.id)
    
    _canonical_count = Repo.one(
      from m in Movie,
      where: m.id in ^movie_ids and
             fragment("? IS NOT NULL", m.canonical_sources) and
             fragment("? != ?", m.canonical_sources, fragment("?::jsonb", "{}")),
      select: count(m.id)
    ) || 0
    
    # Also count individual canonical source appearances for more granular scoring
    breakdown = Repo.query!(
      "SELECT 
        COUNT(CASE WHEN canonical_sources ? $1 THEN 1 END) as count_1001,
        COUNT(CASE WHEN canonical_sources ? $2 THEN 1 END) as count_criterion,
        COUNT(CASE WHEN canonical_sources ? $3 THEN 1 END) as count_nfr,
        COUNT(CASE WHEN canonical_sources ? $4 THEN 1 END) as count_sight_sound
      FROM movies 
      WHERE id = ANY($5)",
      ["1001_movies", "criterion", "national_film_registry", "sight_sound_critics_2022", movie_ids]
    )
    
    [count_1001, count_criterion, count_nfr, count_sight_sound] = List.first(breakdown.rows)
    
    # Return total appearances across all canonical sources
    count_1001 + count_criterion + count_nfr + count_sight_sound
  end
  
  defp count_high_rated_movies(movies) do
    movie_ids = Enum.map(movies, & &1.id)
    
    Repo.one(
      from em in "external_metrics",
      where: em.movie_id in ^movie_ids and
             em.source in ["imdb", "tmdb"] and
             em.metric_type == "rating_average" and
             em.value >= ^@high_rating_threshold,
      select: count(fragment("DISTINCT ?", em.movie_id))
    ) || 0
  end
  
  defp count_festival_nominations(person_id) do
    result = Repo.query!(
      "SELECT COUNT(DISTINCT fn.id) as nomination_count
      FROM movie_credits mc
      JOIN festival_nominations fn ON mc.movie_id = fn.movie_id
      WHERE mc.person_id = $1",
      [person_id]
    )
    
    List.first(result.rows) |> List.first() || 0
  end
  
  defp count_festival_wins(person_id) do
    result = Repo.query!(
      "SELECT COUNT(DISTINCT fn.id) as win_count
      FROM movie_credits mc
      JOIN festival_nominations fn ON mc.movie_id = fn.movie_id
      WHERE mc.person_id = $1 AND fn.won = true",
      [person_id]
    )
    
    List.first(result.rows) |> List.first() || 0
  end
  
  defp normalize_score(raw_score, film_count) do
    # Adaptive normalization based on film volume
    # People with more films need higher raw scores to get top ratings
    base_max = case film_count do
      count when count >= 50 -> 800   # Prolific careers
      count when count >= 20 -> 600   # Major careers  
      count when count >= 10 -> 400   # Solid careers
      count when count >= 5 -> 200    # Emerging careers
      _ -> 100                         # Limited careers
    end
    
    # Scale to 0-100, but allow exceptional scores to go higher initially
    score = (raw_score / base_max) * 100
    
    # Apply ceiling at 100 for final score
    min(100.0, score)
  end
  
  # Backward compatibility functions for existing code
  
  @doc """
  Legacy function for backward compatibility. Now calls universal person scoring.
  """
  def calculate_director_score(person_id) do
    case calculate_person_score(person_id) do
      {:ok, score, _components} -> {:ok, score}
      error -> error
    end
  end
  
  @doc """
  Legacy function for backward compatibility.
  """
  def get_top_directors(limit \\ 10) do
    get_top_people_by_role("Directing", limit)
  end
  
  @doc """
  Legacy function for backward compatibility.
  """
  def calculate_all_director_scores do
    calculate_all_person_scores()
  end
end