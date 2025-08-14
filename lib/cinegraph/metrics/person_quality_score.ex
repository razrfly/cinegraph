defmodule Cinegraph.Metrics.PersonQualityScore do
  @moduledoc """
  Calculates and stores Person Quality Scores (PQS) as person metrics.
  
  This is a minimal MVP that focuses on directors first, using:
  - Number of films directed
  - Average ratings of their films
  - Future: Festival wins and nominations
  """
  
  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.People
  alias Cinegraph.Movies.{Movie, ExternalMetric}
  alias Cinegraph.Metrics.PersonMetric
  
  @doc """
  Calculate basic quality score for a director.
  Returns a normalized score between 0 and 100.
  """
  def calculate_director_score(person_id) do
    # Get all movies this person directed
    directed_movies = get_directed_movies(person_id)
    
    if Enum.empty?(directed_movies) do
      {:ok, 0.0}
    else
      # Calculate components
      film_count_score = calculate_film_count_score(length(directed_movies))
      avg_rating_score = calculate_average_rating_score(directed_movies)
      
      # Weight the components (simple equal weighting for MVP)
      total_score = (film_count_score * 0.5 + avg_rating_score * 0.5) * 100
      
      {:ok, Float.round(total_score, 2)}
    end
  end
  
  @doc """
  Store person quality score in person_metrics table.
  """
  def store_person_score(person_id, score, score_type \\ "director_quality", components \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    
    attrs = %{
      person_id: person_id,
      metric_type: score_type,
      score: score,
      components: components,
      metadata: %{
        "version" => "1.0",
        "algorithm" => "basic_mvp"
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
  Calculate scores for all directors in the system.
  """
  def calculate_all_director_scores do
    # Get all people who have directed at least one movie
    directors = get_all_directors()
    
    results = Enum.map(directors, fn director ->
      with {:ok, score} <- calculate_director_score(director.id),
           film_count <- length(get_directed_movies(director.id)),
           components <- %{"film_count" => film_count, "avg_rating" => nil},
           {:ok, _} <- store_person_score(director.id, score, "director_quality", components) do
        {:ok, director.id, score}
      else
        error -> {:error, director.id, error}
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
  end
  
  # Private functions
  
  defp get_directed_movies(person_id) do
    from(mc in "movie_credits",
      where: mc.person_id == ^person_id and 
             mc.department == "Directing" and 
             mc.job == "Director",
      join: m in Movie, on: m.id == mc.movie_id,
      select: m
    )
    |> Repo.all()
  end
  
  defp get_all_directors do
    from(mc in "movie_credits",
      where: mc.department == "Directing" and mc.job == "Director",
      distinct: [mc.person_id],
      select: %{id: mc.person_id}
    )
    |> Repo.all()
    |> Enum.map(fn %{id: person_id} -> 
      People.get_person!(person_id)
    end)
  end
  
  defp calculate_film_count_score(count) do
    # Normalize film count to 0-1 scale
    # Assumes 20+ films is maximum for scoring purposes
    cond do
      count >= 20 -> 1.0
      count >= 10 -> 0.8
      count >= 5 -> 0.6
      count >= 3 -> 0.4
      count >= 1 -> 0.2
      true -> 0.0
    end
  end
  
  defp calculate_average_rating_score(movies) do
    # Get average rating from external metrics
    movie_ids = Enum.map(movies, & &1.id)
    
    avg_rating = 
      from(em in ExternalMetric,
        where: em.movie_id in ^movie_ids and
               em.source == "tmdb" and
               em.metric_type == "rating_average",
        select: avg(em.value)
      )
      |> Repo.one()
    
    case avg_rating do
      nil -> 0.5  # Default middle score if no ratings
      rating ->
        # TMDb ratings are 0-10, normalize to 0-1
        rating / 10.0
    end
  end
  
  @doc """
  Get top directors by quality score.
  """
  def get_top_directors(limit \\ 10) do
    from(pm in PersonMetric,
      where: pm.metric_type == "director_quality",
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
end