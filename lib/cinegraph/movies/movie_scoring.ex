defmodule Cinegraph.Movies.MovieScoring do
  @moduledoc """
  Business logic for calculating movie scores and related metrics.
  Extracted from LiveView to improve separation of concerns.
  """

  alias Cinegraph.Repo

  # Helper to normalize DB numerics to floats
  def normalize_number(nil), do: nil
  def normalize_number(%Decimal{} = d), do: Decimal.to_float(d)
  def normalize_number(num) when is_integer(num), do: num / 1.0
  def normalize_number(num) when is_float(num), do: num
  def normalize_number(_), do: nil

  @doc """
  Calculate comprehensive scores for a movie using external metrics,
  festival data, person quality, and collaboration intelligence.
  """
  def calculate_movie_scores(movie) do
    # Get external metrics for this movie
    query = """
    SELECT 
      MAX(CASE WHEN source = 'imdb' AND metric_type = 'rating_average' THEN value END) as imdb_rating,
      MAX(CASE WHEN source = 'imdb' AND metric_type = 'rating_votes' THEN value END) as imdb_votes,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'rating_average' THEN value END) as tmdb_rating,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'rating_votes' THEN value END) as tmdb_votes,
      MAX(CASE WHEN source = 'metacritic' AND metric_type = 'metascore' THEN value END) as metacritic,
      MAX(CASE WHEN source = 'rotten_tomatoes' AND metric_type = 'tomatometer' THEN value END) as rt_tomatometer,
      MAX(CASE WHEN source = 'rotten_tomatoes' AND metric_type = 'audience_score' THEN value END) as rt_audience,
      MAX(CASE WHEN source = 'tmdb' AND metric_type = 'popularity_score' THEN value END) as popularity
    FROM external_metrics
    WHERE movie_id = $1
    """

    metrics =
      case Repo.query(query, [movie.id]) do
        {:ok, %{rows: [row]}} ->
          Enum.zip(
            [
              :imdb_rating,
              :imdb_votes,
              :tmdb_rating,
              :tmdb_votes,
              :metacritic,
              :rt_tomatometer,
              :rt_audience,
              :popularity
            ],
            row
          )
          |> Map.new(fn {k, v} -> {k, normalize_number(v)} end)

        _ ->
          %{}
      end

    # Get festival data
    festival_query = """
    SELECT 
      COUNT(CASE WHEN won = true THEN 1 END) as wins,
      COUNT(*) as nominations
    FROM festival_nominations
    WHERE movie_id = $1
    """

    festival_data =
      case Repo.query(festival_query, [movie.id]) do
        {:ok, %{rows: [[wins, nominations]]}} ->
          %{wins: normalize_number(wins) || 0, nominations: normalize_number(nominations) || 0}

        _ ->
          %{wins: 0, nominations: 0}
      end

    # Get average person quality
    person_query = """
    SELECT AVG(pm.score) as avg_quality
    FROM movie_credits mc
    JOIN person_metrics pm ON pm.person_id = mc.person_id
    WHERE mc.movie_id = $1 AND pm.metric_type = 'quality_score'
    """

    person_quality =
      case Repo.query(person_query, [movie.id]) do
        {:ok, %{rows: [[avg]]}} -> normalize_number(avg) || 50.0
        _ -> 50.0
      end

    # Get collaboration score (based on repeat collaborations)
    collab_query = """
    SELECT AVG(collaboration_count) as avg_collab
    FROM (
      SELECT c.collaboration_count
      FROM collaborations c
      JOIN movie_credits mc1 ON mc1.person_id = c.person_a_id
      JOIN movie_credits mc2 ON mc2.person_id = c.person_b_id
      WHERE mc1.movie_id = $1 AND mc2.movie_id = $1
      LIMIT 20
    ) sub
    """

    collab_score =
      case Repo.query(collab_query, [movie.id]) do
        {:ok, %{rows: [[avg]]}} ->
          # Convert average collaboration count to a score (more collabs = higher score)
          avg_val = normalize_number(avg) || 0.0
          min(100.0, avg_val * 15.0)

        _ ->
          50.0
      end

    # Calculate component scores (0-10 scale)
    popular_opinion = calculate_popular_opinion(metrics)
    industry_recognition = calculate_industry_recognition(festival_data)
    cultural_impact = calculate_cultural_impact(movie, metrics)
    # Convert from 0-100 to 0-10
    people_quality_score = person_quality / 10.0
    # Convert from 0-100 to 0-10
    collaboration_intelligence = collab_score / 10.0

    # Calculate overall score (weighted average)
    overall =
      popular_opinion * 0.45 +
        industry_recognition * 0.15 +
        cultural_impact * 0.15 +
        people_quality_score * 0.15 +
        collaboration_intelligence * 0.10

    %{
      overall_score: Float.round(overall, 1),
      components: %{
        popular_opinion: Float.round(popular_opinion, 1),
        industry_recognition: Float.round(industry_recognition, 1),
        cultural_impact: Float.round(cultural_impact, 1),
        people_quality: Float.round(people_quality_score, 1),
        collaboration_intelligence: Float.round(collaboration_intelligence, 1)
      },
      raw_metrics: metrics
    }
  end

  @doc """
  Calculate popular opinion score based on all rating sources.
  """
  def calculate_popular_opinion(metrics) do
    imdb = Map.get(metrics, :imdb_rating, 0) || 0
    tmdb = Map.get(metrics, :tmdb_rating, 0) || 0
    rt_audience = Map.get(metrics, :rt_audience, 0) || 0
    metacritic = Map.get(metrics, :metacritic, 0) || 0
    rt_tomatometer = Map.get(metrics, :rt_tomatometer, 0) || 0

    scores =
      [
        imdb,
        tmdb,
        rt_audience / 10.0,
        metacritic / 10.0,
        rt_tomatometer / 10.0
      ]
      |> Enum.filter(&(&1 > 0))

    if length(scores) > 0 do
      Enum.sum(scores) / length(scores)
    else
      5.0
    end
  end

  @doc """
  Calculate industry recognition based on festival wins and nominations.
  """
  def calculate_industry_recognition(festival_data) do
    wins = Map.get(festival_data, :wins, 0)
    nominations = Map.get(festival_data, :nominations, 0)

    # Score based on wins and nominations (capped at 10)
    min(10.0, wins * 2.0 + nominations * 0.5)
  end

  @doc """
  Calculate cultural impact based on canonical sources and popularity.
  """
  def calculate_cultural_impact(movie, metrics) do
    # Check canonical sources
    canonical_count =
      if movie.canonical_sources && map_size(movie.canonical_sources) > 0 do
        map_size(movie.canonical_sources)
      else
        0
      end

    # Check popularity
    popularity = Map.get(metrics, :popularity, 0) || 0

    popularity_score =
      if popularity > 0 do
        # Normalize on log scale
        :math.log(popularity + 1) / :math.log(1000)
      else
        0
      end

    # Combine canonical presence and popularity
    min(10.0, canonical_count * 2.0 + popularity_score * 5.0)
  end

  @doc """
  Calculate collaboration strength based on movies and their average score.
  """
  def calculate_collaboration_strength(movies) do
    # Based on number of movies and their average score
    count = length(movies)

    avg_score =
      if count > 0 do
        scores = movies |> Enum.map(&Map.get(&1, :score)) |> Enum.filter(&(not is_nil(&1)))

        if length(scores) > 0 do
          Enum.sum(scores) / length(scores)
        else
          5.0
        end
      else
        5.0
      end

    # Strength is combination of quantity and quality
    min(10.0, count * 2.0 + avg_score / 2.0)
  end

  @doc """
  Get score for a single movie (used in timeline calculations).
  """
  def get_movie_score(movie_id) do
    query = """
    SELECT AVG(value) 
    FROM external_metrics 
    WHERE movie_id = $1 
      AND source IN ('imdb', 'tmdb') 
      AND metric_type = 'rating_average'
    """

    case Repo.query(query, [movie_id]) do
      {:ok, %{rows: [[score]]}} ->
        score_val = normalize_number(score)
        if score_val, do: Float.round(score_val, 1), else: nil

      _ ->
        nil
    end
  end
end
