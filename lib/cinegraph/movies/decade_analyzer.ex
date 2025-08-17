defmodule Cinegraph.Movies.DecadeAnalyzer do
  @moduledoc """
  Analyzes movie distribution across decades for the 1001 Movies list.
  Provides historical analysis and predictive capabilities for future editions.
  """

  import Ecto.Query
  alias Cinegraph.Repo
  alias Cinegraph.Movies.Movie

  @doc """
  Gets comprehensive statistics for all decades with 1001 Movies data.
  """
  def get_decade_distribution do
    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        where: not is_nil(m.release_date),
        select: %{
          decade: fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date),
          count: count(m.id)
        },
        group_by: fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date),
        order_by: fragment("FLOOR(EXTRACT(YEAR FROM ?) / 10) * 10", m.release_date)

    results = Repo.all(query)
    total = Enum.reduce(results, 0, fn %{count: c}, acc -> acc + c end)

    Enum.map(results, fn %{decade: decade, count: count} ->
      decade_int = case decade do
        %Decimal{} -> Decimal.to_integer(decade)
        val when is_float(val) -> trunc(val)
        val when is_integer(val) -> val
      end
      
      %{
        decade: decade_int,
        count: count,
        percentage: if(total > 0, do: Float.round(count * 100.0 / total, 2), else: 0.0),
        average_per_year: Float.round(count / 10.0, 1)
      }
    end)
  end

  @doc """
  Gets detailed statistics for a specific decade.
  """
  def get_decade_stats(decade) when is_integer(decade) do
    start_year = decade
    end_year = decade + 9

    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        where: fragment("EXTRACT(YEAR FROM ?) >= ?", m.release_date, ^start_year),
        where: fragment("EXTRACT(YEAR FROM ?) <= ?", m.release_date, ^end_year),
        select: %{
          year: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
          title: m.title,
          release_date: m.release_date,
          edition: fragment("?->'1001_movies'->>'edition'", m.canonical_sources)
        },
        order_by: m.release_date

    movies = Repo.all(query)
    
    year_counts = 
      movies
      |> Enum.group_by(fn movie -> 
        case movie.year do
          %Decimal{} -> Decimal.to_integer(movie.year)
          val when is_float(val) -> trunc(val)
          val when is_integer(val) -> val
        end
      end)
      |> Enum.map(fn {year, movies} -> {year, length(movies)} end)
      |> Map.new()

    %{
      decade: decade,
      total_count: length(movies),
      movies: movies,
      year_distribution: year_counts,
      average_per_year: Float.round(length(movies) / 10.0, 1),
      peak_year: find_peak_year(year_counts),
      historical_context: get_historical_context(decade)
    }
  end

  @doc """
  Predicts likely additions for future years based on historical patterns.
  """
  def predict_future_additions(start_year, end_year) when start_year <= end_year do
    # Calculate historical averages from recent complete decades
    recent_avg = calculate_recent_average()
    
    # Factor in declining trend
    trend_adjustment = calculate_trend_adjustment(start_year)
    
    # Generate predictions
    years = start_year..end_year
    
    Enum.map(years, fn year ->
      base_prediction = recent_avg * trend_adjustment
      
      %{
        year: year,
        predicted_count: round(base_prediction),
        confidence_range: {
          round(base_prediction * 0.8),
          round(base_prediction * 1.2)
        },
        factors: %{
          base_average: Float.round(recent_avg, 2),
          trend_adjustment: Float.round(trend_adjustment, 3),
          festival_boost: estimate_festival_boost(year)
        }
      }
    end)
  end

  @doc """
  Compares two editions of the 1001 Movies list.
  Returns movies added and removed between editions.
  """
  def compare_editions(edition1, edition2) do
    query1 = 
      from m in Movie,
        where: fragment("?->'1001_movies'->>'edition' = ?", m.canonical_sources, ^to_string(edition1)),
        select: %{
          id: m.id, 
          title: m.title, 
          year: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
          position: fragment("?->'1001_movies'->>'list_position'", m.canonical_sources)
        }

    query2 = 
      from m in Movie,
        where: fragment("?->'1001_movies'->>'edition' = ?", m.canonical_sources, ^to_string(edition2)),
        select: %{
          id: m.id, 
          title: m.title, 
          year: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
          position: fragment("?->'1001_movies'->>'list_position'", m.canonical_sources)
        }

    movies1 = Repo.all(query1)
    movies2 = Repo.all(query2)
    
    ids1 = MapSet.new(movies1, & &1.id)
    ids2 = MapSet.new(movies2, & &1.id)

    added_ids = MapSet.difference(ids2, ids1) |> MapSet.to_list()
    removed_ids = MapSet.difference(ids1, ids2) |> MapSet.to_list()

    added_movies = Enum.filter(movies2, fn m -> m.id in added_ids end)
    removed_movies = Enum.filter(movies1, fn m -> m.id in removed_ids end)

    %{
      edition1: edition1,
      edition2: edition2,
      added: Enum.sort_by(added_movies, & &1.year, :desc),
      removed: Enum.sort_by(removed_movies, & &1.year, :desc),
      net_change: length(added_movies) - length(removed_movies),
      total_edition1: length(movies1),
      total_edition2: length(movies2)
    }
  end

  @doc """
  Gets movies that are strong candidates for future 1001 editions.
  """
  def get_prediction_candidates(year, limit \\ 20) do
    # Query for highly rated movies from the year that aren't in 1001 yet
    query =
      from m in Movie,
        where: fragment("EXTRACT(YEAR FROM ?) = ?", m.release_date, ^year),
        where: fragment("NOT (? \\? ?)", m.canonical_sources, "1001_movies"),
        left_join: em in assoc(m, :external_metrics),
        where: em.source in ["tmdb", "imdb", "metacritic", "rotten_tomatoes"],
        group_by: [m.id, m.title, m.release_date],
        having: avg(em.value) > 7.5,
        select: %{
          id: m.id,
          title: m.title,
          release_date: m.release_date,
          avg_score: avg(em.value),
          score_count: count(em.id)
        },
        order_by: [desc: avg(em.value)],
        limit: ^limit

    candidates = Repo.all(query)
    
    # Add prediction scores
    Enum.map(candidates, fn candidate ->
      Map.put(candidate, :prediction_score, calculate_prediction_score(candidate))
    end)
    |> Enum.sort_by(& &1.prediction_score, :desc)
  end

  @doc """
  Gets available editions for comparison.
  """
  def get_available_editions do
    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        select: fragment("?->'1001_movies'->>'edition'", m.canonical_sources),
        distinct: true,
        order_by: fragment("?->'1001_movies'->>'edition'", m.canonical_sources)

    Repo.all(query)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort(:desc)
  end

  @doc """
  Gets year-by-year statistics for recent years to show trends.
  """
  def get_recent_year_trends(start_year \\ 2010) do
    current_year = Date.utc_today().year
    
    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        where: fragment("EXTRACT(YEAR FROM ?) >= ?", m.release_date, ^start_year),
        where: fragment("EXTRACT(YEAR FROM ?) <= ?", m.release_date, ^current_year),
        select: %{
          year: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
          count: count(m.id)
        },
        group_by: fragment("EXTRACT(YEAR FROM ?)", m.release_date),
        order_by: fragment("EXTRACT(YEAR FROM ?)", m.release_date)

    Repo.all(query)
    |> Enum.map(fn %{year: year, count: count} -> 
      year_int = case year do
        %Decimal{} -> Decimal.to_integer(year)
        val when is_float(val) -> trunc(val)
        val when is_integer(val) -> val
      end
      %{year: year_int, count: count} 
    end)
  end

  # Private functions

  defp calculate_recent_average do
    # Average from 2010-2019 (complete recent decade)
    query =
      from m in Movie,
        where: fragment("? \\? ?", m.canonical_sources, "1001_movies"),
        where: fragment("EXTRACT(YEAR FROM ?) BETWEEN 2010 AND 2019", m.release_date),
        select: count(m.id)

    count = Repo.one(query) || 0
    count / 10.0
  end

  defp calculate_trend_adjustment(year) do
    # Declining trend: each decade sees ~5% fewer additions
    decades_from_2010 = (year - 2010) / 10.0
    :math.pow(0.95, decades_from_2010)
  end

  defp estimate_festival_boost(year) do
    # Major festival years might see 10-20% boost
    case rem(year, 5) do
      0 -> 1.15  # Anniversary years often see retrospectives
      _ -> 1.0
    end
  end

  defp find_peak_year(year_counts) when map_size(year_counts) == 0, do: nil
  defp find_peak_year(year_counts) do
    {year, _count} = Enum.max_by(year_counts, fn {_year, count} -> count end)
    year
  end

  defp get_historical_context(decade) do
    contexts = %{
      1920 => "Silent era and early talkies",
      1930 => "Golden Age of Hollywood begins",
      1940 => "War films and film noir emergence", 
      1950 => "Post-war cinema and international movements",
      1960 => "New Wave movements worldwide",
      1970 => "New Hollywood and auteur cinema",
      1980 => "Blockbuster era and independent film rise",
      1990 => "Digital revolution begins",
      2000 => "Digital cinema and globalization",
      2010 => "Streaming era and franchise dominance",
      2020 => "Pandemic era and streaming wars"
    }
    
    Map.get(contexts, decade, "Contemporary cinema")
  end

  defp calculate_prediction_score(candidate) do
    # Simplified scoring algorithm
    base_score = candidate.avg_score * 10
    
    # Boost for multiple rating sources
    source_multiplier = min(candidate.score_count / 4.0, 1.5)
    
    Float.round(base_score * source_multiplier, 2)
  end
end