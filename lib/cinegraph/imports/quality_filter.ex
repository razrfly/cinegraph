defmodule Cinegraph.Imports.QualityFilter do
  @moduledoc """
  Configurable quality filters for import decisions.

  Provides modular criteria for determining whether movies and people
  should be fully imported, soft imported, or skipped entirely.
  """

  require Logger

  # Movie quality criteria configuration
  # Requires 2 out of 4 criteria for full import (lowered from 4 to increase data inclusion)
  # This balanced approach captures both mainstream and niche cinema while filtering out 
  # low-quality entries. Criteria: poster, votes, popularity, release_date
  @movie_min_required 2

  # Configurable quality thresholds - relaxed to improve data coverage
  # These thresholds were lowered after analysis showed overly restrictive filtering
  # was excluding valuable content, particularly international and independent films
  @quality_thresholds %{
    # Lowered from 25 - captures indie films with engaged audiences
    min_votes: 10,
    # Lowered from 5.0 - includes art house and foreign cinema
    min_popularity: 0.5
  }

  # Person quality criteria configuration
  @key_departments ["Acting", "Directing", "Writing"]

  # Movie criteria check functions
  defp check_has_poster(movie), do: !is_nil(movie["poster_path"])
  defp check_has_votes(movie), do: (movie["vote_count"] || 0) >= @quality_thresholds.min_votes

  defp check_has_popularity(movie),
    do: (movie["popularity"] || 0) >= @quality_thresholds.min_popularity

  defp check_has_release_date(movie), do: !is_nil(movie["release_date"])

  # Person criteria check functions
  defp check_person_has_profile(person), do: !is_nil(person["profile_path"])
  defp check_person_has_popularity(person), do: (person["popularity"] || 0) >= 0.5

  @doc """
  Determines if a movie should be fully imported.

  Returns {:full_import, met_criteria} or {:soft_import, failed_criteria}
  """
  def evaluate_movie(movie_data) do
    # Define criteria with their check functions
    criteria = [
      {:has_poster, &check_has_poster/1},
      {:has_votes, &check_has_votes/1},
      {:has_popularity, &check_has_popularity/1},
      {:has_release_date, &check_has_release_date/1}
    ]

    # Evaluate each criterion
    results =
      Enum.map(criteria, fn {name, check_fn} ->
        {name, check_fn.(movie_data)}
      end)

    # Count how many criteria were met
    met_criteria = Enum.filter(results, fn {_name, passed} -> passed end)
    failed_criteria = Enum.filter(results, fn {_name, passed} -> !passed end)

    if length(met_criteria) >= @movie_min_required do
      {:full_import, Enum.map(met_criteria, &elem(&1, 0))}
    else
      {:soft_import, Enum.map(failed_criteria, &elem(&1, 0))}
    end
  end

  @doc """
  Determines if a person should be imported.

  Returns true if the person meets quality criteria, false otherwise.
  """
  def should_import_person?(person_data) do
    dept = person_data["known_for_department"] || "Unknown"

    if dept in @key_departments do
      # For key roles (Acting/Directing/Writing), require ANY criterion
      check_person_has_profile(person_data) || check_person_has_popularity(person_data)
    else
      # For other departments, require ALL criteria
      check_person_has_profile(person_data) && check_person_has_popularity(person_data)
    end
  end

  @doc """
  Logs quality decision for analytics.
  """
  def log_quality_decision(type, tmdb_id, decision, criteria_results) do
    Logger.info("""
    Quality Decision:
      Type: #{type}
      ID: #{tmdb_id}
      Decision: #{decision}
      Criteria: #{inspect(criteria_results)}
    """)
  end

  @doc """
  Gets current configuration for runtime adjustment.
  """
  def get_movie_config do
    %{
      min_required: @movie_min_required,
      criteria: [
        :has_poster,
        :has_votes,
        :has_popularity,
        :has_release_date
      ],
      thresholds: @quality_thresholds
    }
  end

  def get_person_config do
    %{
      key_departments: @key_departments
    }
  end

  @doc """
  Analyzes why a movie failed quality checks.
  """
  def analyze_movie_failure(movie_data) do
    case evaluate_movie(movie_data) do
      {:soft_import, failed_criteria} ->
        %{
          tmdb_id: movie_data["id"],
          title: movie_data["title"],
          failed_criteria: failed_criteria,
          missing_data: %{
            poster: is_nil(movie_data["poster_path"]),
            votes: (movie_data["vote_count"] || 0) < @quality_thresholds.min_votes,
            popularity: (movie_data["popularity"] || 0) < @quality_thresholds.min_popularity,
            release_date: is_nil(movie_data["release_date"])
          }
        }

      _ ->
        nil
    end
  end
end
